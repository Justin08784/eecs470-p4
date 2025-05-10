/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_if.sv                                         //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

typedef struct packed {
    logic [`N-1:0] en;
    WADDR [`N-1:0] pc;
} fetch2btb;
typedef struct packed {
    logic [`N-1:0] vld; // i.e. hit?
    WADDR [`N-1:0] tgt;
} btb2fetch;
typedef struct packed {
    logic [`N-1:0] en;
    WADDR [`N-1:0] pc;
    WADDR [`N-1:0] tgt;
} retire2btb;

module btb #(parameter
    NUM_LINES=256
) (
    input clock,
    input reset,

    // query (fetch)
    input   fetch2btb   f_in,
    output  btb2fetch   f_out,

    // write (retire)
    input   retire2btb  r_in
);
    localparam ASSOC = 2;
    localparam NUM_SETS = NUM_LINES / ASSOC;

    localparam SID_BITS     = $clog2(NUM_SETS);
    localparam TAG_BITS     = $bits(WADDR) - SID_BITS;
    typedef logic [SID_BITS-1:0] SID;
    /*NOTE: We don't need a full tag. The BTB doesn't need
    perfect accuracy since it is a predictor anyways. Can
    use smaller tag and save area.  */
    typedef logic [TAG_BITS-1:0] TAG;
    typedef logic [$clog2(ASSOC)-1:0]   WAY;

    function automatic TAG get_tag(input WADDR waddr);
        return waddr[$bits(WADDR)-1:SID_BITS];
    endfunction
    function automatic SID get_sid(input WADDR waddr);
        return waddr[SID_BITS-1:0];
    endfunction

    typedef struct packed {
        logic   [NUM_SETS-1:0][ASSOC-1:0] vld;
        TAG     [NUM_SETS-1:0][ASSOC-1:0] tag;
        logic   [NUM_SETS-1:0] lru; // 1 bit is enough for 2-way
    } HEADER;
    HEADER hdr, hdr_n;
    WADDR [NUM_SETS-1:0][ASSOC-1:0] tgt, tgt_n;

    typedef struct packed {
        logic   hit;
        TAG     tag;
        WAY     way;
        SID     sid;
    } LOC;
    function automatic LOC locate(
        input HEADER    hdr,
        input WADDR     waddr
    );
        logic   hit;
        TAG     tag;
        WAY     way;
        SID     sid;
        tag = get_tag(waddr);
        sid = get_sid(waddr);

        way = 0;
        hit = 0;
        for (int w = 0; w < ASSOC; ++w) begin
            if (hdr.vld[sid][w] && (tag == hdr.tag[sid][w])) begin
                hit = 1;
                way = w;
                break;
            end
        end

        return '{
            hit : hit,
            tag : tag,
            way : way,
            sid : sid
        };
    endfunction

    logic [NUM_SETS-1:0] evict;
    logic [NUM_SETS-1:0][ASSOC-1:0] free_gnts;
    WAY   [NUM_SETS-1:0] free_ways;
    WAY   [NUM_SETS-1:0] wr_ways;
    generate
    for (genvar s = 0; s < NUM_SETS; ++s) begin : gen_sel_free
        psel_gen #(
            .WIDTH(ASSOC),
            .REQS(1)
        ) sel_free (
            .req (~hdr.vld[s]),
            .gnt (free_gnts[s])
        );
    end
    endgenerate

    always_comb begin
        foreach (evict[s])
            evict[s] = !(|free_gnts[s]);

        free_ways = '0;
        foreach (free_gnts[s, w]) begin
            if (!free_gnts[s][w])
                continue;
            free_ways[s] |= w;
        end

        wr_ways = '0;
        foreach (wr_ways[s]) begin
            wr_ways[s] = evict[s]
                ? hdr.lru[s]    // overwrite a line
                : free_ways[s];  // free entry available
        end
    end


    always_comb begin
        hdr_n = hdr;
        tgt_n = tgt;

        // fetch
        f_out = '0;
        foreach (f_in.en[i]) begin
            LOC loc;
            loc = locate(hdr, f_in.pc[i]);
            f_out.vld[i] = loc.hit;
            f_out.tgt[i] = tgt[loc.sid][loc.way];

            if (f_in.en[i] && loc.hit)
                hdr_n.lru[loc.sid] = !loc.way;
        end

        // retire
        foreach (r_in.en[i]) begin
            SID sid;
            TAG tag;
            WAY way;

            sid = get_sid(r_in.pc[i]);
            tag = get_tag(r_in.pc[i]);
            way = wr_ways[sid];

            hdr_n.vld[sid][way] = 1;
            hdr_n.tag[sid][way] = tag;
            hdr_n.lru[sid] = !way;
            tgt_n[sid][way] = r_in.tgt[i];
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            hdr <= '0;
            tgt <= '0;
        end else begin
            hdr <= hdr_n;
            tgt <= tgt_n;
        end
    end
endmodule


module stage_if_p4 (
`ifdef DEBUG
    output  DBG_fetch dbg,
`endif

    input   clock,
    input   reset,
    input   flush,
    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   retire2fetch r_in,

    output  fetch2mem   mem_out,
    input   mem2fetch   mem_in
);
    WADDR PC_reg;       // base PC for this cycle
    WADDR [`N:0] PC_n;  // PC_n[m] := next PC if we fetch "m" this cycle (inaccurate past the 1st branch)

    logic [$clog2(`N):0]    free_scnt, used_scnt, f_cnt;
    IF_ID_PACKET [`N-1:0]   f_dat;

    always_comb begin
        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);

        PC_n[0] = PC_reg;
        for (int i = 0; i < `N; ++i) begin
            PC_n[i + 1] = PC_reg + i + 1;
            mem_out.PCs[i] = w2addr(PC_n[i]);
        end
    end

    fetch2btb f2btb;
    btb2fetch btb2f;
    logic [`N-1:0] is_brch;
    logic [`N-1:0] pred;
    WADDR [`N-1:0] pred_tgt;
    always_comb begin
        logic woff;
        foreach (is_brch[i]) begin
            woff = PC_n[i][0];
            is_brch[i] = (mem_in.insn_md[i][woff].cond_branch
                       || mem_in.insn_md[i][woff].uncond_branch);

            f2btb.pc[i] = PC_n[i];
            f2btb.en[i] = is_brch[i];
                // or should we just do: (i < f_cnt) && is_brch[i] ?

            pred[i]     = is_brch[i] && btb2f.vld[i];
            pred_tgt[i] = btb2f.tgt[i];
        end
    end
    btb btb0 (
        .clock(clock),
        .reset(reset),

        .f_in (f2btb),
        .f_out(btb2f),

        .r_in ('0) // FIXME
    );

    always_comb begin
        // stop fetching beyond the first predicted taken branch
        f_cnt = 0;
        for (int i = 0; i < `N; ++i) begin
            if (i >= free_scnt)
                break;
            f_cnt = i + 1;
            if (pred[i]) begin
                break;
            end
        end

        for (int unsigned i = 0; i < `N; ++i) begin
            logic woff;
            woff = PC_n[i][0];

            f_dat[i] = '{
                inst    : mem_in.data[i].word_level[woff],
                PC      : PC_n[i],
                pred    : pred[i],
                pred_tgt: pred_tgt[i]
            };
        end
    end

    fifo #(
        .DEPTH(2*`N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) dut (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .wr_en_cnt  (f_cnt),
        .wr_data    (f_dat),
        .rd_en_cnt  (d_out.f_en_cnt),
        .rd_data    (d_out.f_dat),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;                    // initial PC value is 0 (the memory address where our program starts)
        end else if (flush) begin
            PC_reg <= r_in.corrected_PC;    // update to a taken branch (does not depend on valid bit)...
        end else begin                      // ...or transition to next PC if valid
            PC_reg <= 
                f_cnt == 0    ? PC_reg :
                pred[f_cnt-1] ? pred_tgt[f_cnt-1] : PC_n[f_cnt];
        end
    end

`ifdef DEBUG
    assign dbg = '{
        flush : flush,
        d_in  : d_in,
        d_out : d_out,
        r_in  : r_in,
        mem_out_PCs : mem_out_PCs, 
        mem_in_data : mem_in_data
    };
`endif

endmodule // stage_if
