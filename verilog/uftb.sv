`include "sys_defs.svh"

localparam FTQ_SZ = 32;

typedef struct packed {
    WADDR       base;   // base address of FB

    // pared down FTB entry
    logic       ft;     // fallthrough? else took a branch
    logic [3:0] off;    // ft ? end_off : br_slot[0/1].off
        // if a branch
    logic       vld;
    // WADDR       tgt;
        // Q: Why omit? A: if branch, next FTQ entry's base is branch target
    logic       always_take;
    logic       cond;
} FTQ_ENTRY;

typedef struct packed {
`ifdef DEBUG
    BMASK   b1hot;
`endif
    WADDR   PC;

    /* TODO: have a single take, tgt field, initialized by the BPU, but later
    overwritten by decode/EX when the branch resolves */
    logic   pred;
    WADDR   pred_tgt;
    logic   take;
    WADDR   tgt;

    logic   ret;    // is a ret instruction? (heuristic only; see predecoder for spec)
    logic   cond;   // is a conditional branch?

    logic   [GHR_LEN-1:0] hash; // gshare hash index
    logic   [`N-1:0][$clog2(GHR_BUF_SZ)-1:0] ghr_base;
    logic   pred_bim;
    logic   pred_gshare;

    logic   [3:0] off; // offset in fb (if taken, equals offset in FTQ_ENTRY)
    logic   [$clog2(FTQ_SZ)-1:0] ftq_idx; // pointer to owning FTQ entry
        /* Since multiple contiguous BTQ entries may be associated with an FTQ entry,
        an FTQ entry cannot dequeue until the "last" in the BTQ entry span is reached. */
} _BTQ_ENTRY;

module uftb #(
    parameter NUM_LINES=16
    // fully associative
) (
    input clock,
    input reset,

    // fetch query
    input   WADDR       i_qry, // branch pc

    output  logic       o_vld,
    output  FTB_ENTRY   o_tgt,

    // puq updates
    input   logic       i_uen,
    input   FTB_UPD_PKT i_udat
);
    localparam TAG_SKIMP = 0;
        /* TAG_SKIMP = how many bits to drop from the full tag that is required to
        eliminate aliases (0 for no alias).

        Increasing will result in more aliases, but acceptable for
        BTB since they are speculative. Can be worth to save area and logic. */
    localparam TAG_BITS = $bits(WADDR) - TAG_SKIMP;
    typedef logic [TAG_BITS-1:0]                TAG;
    typedef logic [$clog2(NUM_LINES)-1:0]       WAY;
    typedef logic [NUM_LINES-1:0][NUM_LINES-1:0]AGE;

    function automatic TAG get_tag(input WADDR waddr);
        return waddr[TAG_BITS-1:0];
    endfunction

    typedef struct packed {
        logic   [NUM_LINES-1:0] vld;
        logic   [NUM_LINES-1:0] dirty; // TODO: unused. use when doing multi-level FTB
        TAG     [NUM_LINES-1:0] tag;
        AGE     age;
            /* TODO:
            1. implement pLRU (tree or bit) for assoc ≥ 8.
            Maybe auto-switch between LRU and pRLU according to assoc
            parameter, keeping LRU for assoc < 8. 
            2. We can save bits in the LRU age matrix by storing the upper-triangle
            bits (top right above diagonal). */
    } HEADER;
    HEADER hdr, hdr_n;
    FTB_ENTRY [NUM_LINES-1:0] tgt, tgt_n;

    typedef struct packed {
        logic   hit;
        TAG     tag;
        WAY     way;
    } LOC;
    function automatic LOC locate(
        input HEADER    hdr,
        input WADDR     waddr
    );
        logic   hit;
        TAG     tag;
        WAY     way;
        tag = get_tag(waddr);

        way = 0;
        hit = 0;
        for (int w = 0; w < NUM_LINES; ++w) begin
            if (hdr.vld[w] && (tag == hdr.tag[w])) begin
                hit = 1;
                way = w;
                break;
            end
        end

        return '{
            hit : hit,
            tag : tag,
            way : way
        };
    endfunction

    function automatic AGE update_lru(
        input AGE age,
        input WAY way
    );
        AGE rv;
        rv = age;
        foreach(rv[i, j]) begin
            if (i == way)
                rv[i][j] = i == j;
            else if (j == way)
                rv[i][j] = 1;
        end
        return rv;
    endfunction

    function automatic FTB_ENTRY wr_br0(
        input FTB_ENTRY     dst,
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        rv = dst;

        rv.br_slot[0] = '{
            vld : 1,
            tgt : udat.tgt,
            off : udat.pc_off,
            always_take : udat.always_take 
        };

        return rv;
    endfunction

    function automatic FTB_ENTRY wr_br1(
        input FTB_ENTRY     dst,
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        rv = dst;

        rv.br_slot[1] = '{
            vld : 1,
            tgt : udat.tgt,
            off : udat.pc_off,
            always_take : udat.always_take
        };

        rv.md1 = udat.md;

        return rv;
    endfunction

    function automatic FTB_ENTRY update_fb(
        output logic        spill,
        input FTB_ENTRY     dst,
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        logic [1:0] vld;
        logic eq0, eq1, lt0, lt1, gt1;

        rv = dst;
        vld[0] = dst.br_slot[0].vld;
        vld[1] = dst.br_slot[1].vld;
        eq0 = udat.pc_off == dst.br_slot[0].off;
        eq1 = udat.pc_off == dst.br_slot[1].off;
        lt0 = udat.pc_off <  dst.br_slot[0].off;
        lt1 = udat.pc_off <  dst.br_slot[1].off;
        gt1 = !(eq1 || lt1); // should be equiv. to "greater than" via trichotomy
            // gt1 = udat.pc_off >  dst.br_slot[1].off;

        spill = vld[1] && gt1;
        if (udat.md.cond) begin
            if (vld[0] && lt0) begin
                // shift left
                rv.br_slot[1]   = rv.br_slot[0];
                rv.md1.cond     = 1;
            end

            rv = (
                (vld[1] &&   eq1)
            ||  (vld[0] && !(eq0 || lt0))
            )
                ? wr_br1(rv, udat)
                : wr_br0(rv, udat);

        end else begin
            if (vld[0] && (eq0 || lt0)) begin
                // invalidate to ensure off[0] < off[1]
                rv.br_slot[0].vld = 0;
            end

            rv = wr_br1(rv, udat);
        end

            // if (vld[0]) begin
            //     if (lt0) begin
            //         // shift left
            //         rv.br_slot[1]   = rv.br_slot[0];
            //         rv.md1.cond     = 1;
            //     end

            //     rv = (eq0 || lt0)
            //         ? wr_br0(rv, udat)
            //         : wr_br1(rv, udat);
            // end else
            //     rv = wr_br0(rv, udat);


        // if (vld[0] && eq0)
        //     if (udat.md.cond)
        //         rv = wr_br0(rv, udat);
        //     else begin
        //         // invalidate to ensure off[0] < off[1]
        //         rv.br_slot[0].vld = 0;

        //         rv = wr_br1(rv, udat);
        //     end
        // else if (vld[1] && eq1)
        //     rv = wr_br1(rv, udat);
        // else
        //     if (!vld[0])
        //         rv = udat.md.cond
        //             ? wr_br0(rv, udat)
        //             : wr_br1(rv, udat);
        //     else
        //         if (lt0)
        //             if (udat.md.cond) begin
        //                 // shift left
        //                 rv.br_slot[1]   = rv.br_slot[0];
        //                 rv.md1.cond     = 1;

        //                 rv = wr_br0(rv, udat);
        //             end else begin
        //                 // invalidate to ensure off[0] < off[1]
        //                 rv.br_slot[0].vld = 0;

        //                 rv = wr_br1(rv, udat);
        //             end
        //         else
        //             rv = wr_br1(rv, udat);

        rv.end_off = rv.br_slot[1].vld
            ? rv.br_slot[1].off
            : 15;

        return rv;
    endfunction

    function automatic FTB_ENTRY create_fb(
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv = '0;

        if (udat.md.cond) begin
            rv.end_off = 15;
            rv = wr_br0(rv, udat);

        end else begin
            rv.end_off = udat.pc_off;
            rv = wr_br1(rv, udat);

        end

        return rv;
    endfunction

    logic [NUM_LINES-1:0] lru;
    WAY lru_way;
    always_comb begin
        foreach (lru[w])
            lru[w] = &hdr.age[w];

        lru_way = '0;
        for (int w = 0; w < NUM_LINES; ++w) begin
            if (lru[w])
                lru_way = w;
        end
    end

    // fetch
    always_comb begin
        LOC loc;
        loc = locate(hdr, i_qry);

        o_vld = loc.hit;
        o_tgt = tgt[loc.way];
    end

    // retire
    always_comb begin
        LOC loc;
        WAY way;
        logic spill;
        FTB_ENTRY wfb; // FTB entry with updates
        logic wen;

        loc = locate(hdr, i_udat.base);
        way = loc.hit ? loc.way : lru_way;
        wfb = loc.hit
            ? update_fb(spill, tgt[loc.way], i_udat)
            : create_fb(i_udat);
        wen = i_uen && (!loc.hit || !spill);

        hdr_n = hdr;
        tgt_n = tgt;

        if (wen) begin
            hdr_n.vld[way]  = 1;
            hdr_n.dirty[way]= 1;
            hdr_n.tag[way]  = loc.tag;
            hdr_n.age       = update_lru(hdr.age, way);
                /* TODO: since every branch queries the FTB (but not every branch
                generates an FTB update) we need an LRU update for reads as well,
                not just writes. */

            tgt_n[way]      = wfb;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            hdr <= '{
                vld     : '0,
                dirty   : '0,
                tag     : '0,
                age     : '1 // *IMPORTANT* empty lines are treated as "oldest"
            };
            tgt <= '0;

        end else begin
            hdr <= hdr_n;
            tgt <= tgt_n;

        end
    end


`ifdef DEBUG
    task automatic print_ftb();
        for (int w = 0; w < NUM_LINES; ++w) begin
            if (!hdr.vld[w]) begin
                $display("  %1d:", w);
                continue;
            end
            $display("  %1d: {tag: 0x%x tgt: %x} ",
                w,
                hdr.tag[w],
                w2addr(tgt[w])
            );
        end
    endtask
`endif
endmodule
