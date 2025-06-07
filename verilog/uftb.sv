`include "sys_defs.svh"

localparam FTQ_SZ = 32;

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

module lru_man #(
    parameter SETW=16
) (
    input   logic [SETW-1:0][SETW-1:0] age,
    input   logic [$clog2(SETW)-1:0] acc_way,

    output  logic [$clog2(SETW)-1:0] lru_way,
    output  logic [SETW-1:0][SETW-1:0] age_n
);
`define LRU_UTRI

`ifdef LRU_UTRI
/* interpret age as an "older than" upper triangle matrix:
age[i][j]
    1) is valid iff i < j
    2) if valid, means way i is "older" than way j */

    logic [SETW-1:0][SETW-1:0] nage;
    logic [SETW-1:0][SETW-1:0] ot;
    logic [SETW-1:0] lruv;
    generate
    assign nage = ~age;
    for (genvar i = 0; i < SETW; ++i) begin
        for (genvar j = 0; j < SETW; ++j) begin
            assign ot[i][j] =
                i <  j ?  age[i][j] :
                i >  j ? nage[j][i] :
                1;
        end
    end

    for (genvar w = 0; w < SETW; ++w) begin
        assign lruv[w] = &ot[w];
    end
    endgenerate

    always_comb begin
        lru_way = '0;
        for (int w = 0; w < SETW; ++w) begin
            if (lruv[w])
                lru_way = w;
        end
    end

    generate
    for (genvar i = 0; i < SETW; ++i) begin
        for (genvar j = i+1; j < SETW; ++j) begin
            assign age_n[i][j] =
                i == acc_way ? 0 :
                j == acc_way ? 1 :
                age[i][j];
        end
    end
    endgenerate

`else
/* interpret age as an "not younger than" full matrix:
age[i][j]
    1) is valid forall i, j
    2) means way i is "not younger" than way j */

    function automatic logic [SETW-1:0][SETW-1:0] update_lru(
        input logic [SETW-1:0][SETW-1:0] age,
        input logic [$clog2(SETW)-1:0] way
    );
        logic [SETW-1:0][SETW-1:0] rv;
        rv = age;
        foreach(rv[i, j]) begin
            if (i == way)
                rv[i][j] = i == j;
            else if (j == way)
                rv[i][j] = 1;
        end
        return rv;
    endfunction

    logic [SETW-1:0] lru;
    generate
    for (genvar w = 0; w < SETW; ++w)
        assign lru[w] = &age[w];
    endgenerate

    always_comb begin
        lru_way = '0;
        for (int w = 0; w < SETW; ++w) begin
            if (lru[w])
                lru_way = w;
        end
    end

    assign age_n = update_lru(age, acc_way);
`endif

endmodule

// custom comparator for 4-bits. Seems to be faster than default synthesis of "<".
function automatic cmp4(
    input   logic [3:0] a,b,
    output  logic eq,
    output  logic lt
);
    logic [3:0] x;
    logic [3:0] l;
    logic eq_lo, eq_hi;
    logic lt_lo, lt_hi;

    x =  a   ^  b;
    l = (~a) &  b;

    eq_lo = ~(x[1] | x[0]);
    lt_lo = l[1] | (~x[1] & l[0]);

    eq_hi = ~(x[3] | x[2]);
    lt_hi = l[3] | (~x[3] & l[2]);

    eq = eq_hi & eq_lo;
    lt = lt_hi | (eq_hi & lt_lo);


    // logic [3:0] lt1, eq1;
    // logic [1:0] lt2, eq2;

    // for (int i = 0; i < 4; ++i) begin
    //     lt1[i] = !a[i] && b[i];
    //     eq1[i] =  a[i] == b[i];
    // end

    // lt2[0] = lt1[1] || (eq1[1] ? lt1[0] : 0);
    // lt2[1] = lt1[3] || (eq1[3] ? lt1[2] : 0);
    // eq2[0] = eq1[0] && eq1[1];
    // eq2[1] = eq1[2] && eq1[3];

    // eq = eq2[0] && eq2[1];
    // lt = lt2[1] || (eq2[1] ? lt2[0] : 0);
endfunction

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
        logic   [NUM_LINES-1:0] hitv;
        logic   hit;
        TAG     tag;
        WAY     way;
        tag = get_tag(waddr);

        for (int w = 0; w < NUM_LINES; ++w)
            hitv[w] = hdr.vld[w] && (tag == hdr.tag[w]);

        hit = |hitv;
        way = 0;
        for (int w = 0; w < NUM_LINES; ++w) begin
            if (hitv[w])
                way = w;
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
        input logic [1:0]   sc,
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        rv = dst;

        rv.br_slot[0] = '{
            sc  : sc,
            vld : 1,
            tgt : udat.tgt,
            off : udat.pc_off,
            always_take : udat.always_take 
        };

        return rv;
    endfunction

    function automatic FTB_ENTRY wr_br1(
        input FTB_ENTRY     dst,
        input logic [1:0]   sc,
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        rv = dst;

        rv.br_slot[1] = '{
            sc  : sc,
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
        logic eq0, eq1, lt0, gt1;

        logic [1:0] sc_new, // new slot sc
                    sc_upd0,// br0 sc updated
                    sc_upd1;// br1 sc updated
        sc_new  = WT;
        sc_upd0 = update_sc(dst.br_slot[0].sc, udat.take);
        sc_upd1 = update_sc(dst.br_slot[1].sc, udat.take);

        rv = dst;
        vld[0] = dst.br_slot[0].vld;
        vld[1] = dst.br_slot[1].vld;
        // eq0 = udat.pc_off == dst.br_slot[0].off;
        // lt0 = udat.pc_off <  dst.br_slot[0].off;
        // eq1 = udat.pc_off == dst.br_slot[1].off;
        // gt1 = udat.pc_off >  dst.br_slot[1].off;

        cmp4(udat.pc_off, dst.br_slot[0].off, eq0, lt0);
        cmp4(dst.br_slot[1].off, udat.pc_off, eq1, gt1);

        spill = vld[1] && gt1;
        if (udat.md.cond) begin
            if (vld[0] && lt0) begin
                // shift left
                rv.br_slot[1]   = rv.br_slot[0];
                rv.md1.cond     = 1;
                rv = wr_br0(rv, sc_new, udat);

            end else begin
                /*
                improved critical path when this assignment was moved into `else`.
                knowledge injection: synthesizer does not know "shift left" and
                "wr_br1" are mutually exclusive (it is based upon the off0 < off1
                invariant)–– the programmer must make explicit what the synthesizer
                cannot infer.
                */

                rv = (
                    (vld[1] &&   eq1)
                ||  (vld[0] && !(eq0 || lt0))
                )
                    ? wr_br1(
                        rv, 
                        (vld[1] && eq1) ? sc_upd1 : sc_new,
                        udat
                    )

                    : wr_br0(
                        rv,
                        (vld[0] && eq0) ? sc_upd0 : sc_new,
                        udat
                    );
            end 

        end else begin
            if (vld[0] && (eq0 || lt0)) begin
                // invalidate to ensure off[0] < off[1]
                rv.br_slot[0].vld = 0;
            end

            rv = wr_br1(
                rv, 
                (vld[1] && eq1) ? sc_upd1 : sc_new,
                udat
            );
        end

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
        FTB_ENTRY rv;
        logic [1:0] sc_new;

        rv = '0;
        sc_new  = WT;

        if (udat.md.cond) begin
            rv.end_off = 15;
            rv = wr_br0(rv, sc_new, udat);

        end else begin
            rv.end_off = udat.pc_off;
            rv = wr_br1(rv, sc_new, udat);

        end

        return rv;
    endfunction

    WAY lru_way, acc_way;
    AGE age_n;
    lru_man #(
        .SETW(NUM_LINES)
    ) lru_man0 (
        .age(hdr.age),
        .acc_way,
        .lru_way,
        .age_n
    );

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
        acc_way = way;
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
            hdr_n.age       = age_n;
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
