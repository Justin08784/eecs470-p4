`include "sys_defs.svh"
module bp #(
    // parameter QUERY_SZ // i.e. number of branch slots, BTB read slots
    // parameter UPD_SZ    = BP_UPD_SZ
) (
    input   clock,
    input   reset,
    input   flush,

    // fetch npc query
    input BRANCH_MD [`N-1:0]    i_md,
    input   WADDR   [`N-1:0]    i_qry, // branch pc

    output  logic   [$clog2(`N):0]  o_lim_cnt, // f_cnt limit (cap at first taken)
    output  logic   [`N-1:0]    o_take,
    output  WADDR   [`N-1:0]    o_tgt,

    input   logic   [`N-1:0]    f_en,

    // puq updates
    input   puq2fetch i_upd
);
    logic [`N-1:0] brch, cond, call, ret;
    generate
    for (genvar i = 0; i < `N; ++i) begin
        assign brch[i] = i_md[i].branch;
        assign cond[i] = i_md[i].cond;
        assign call[i] = i_md[i].call;
        assign ret[i]  = i_md[i].ret;
    end
    endgenerate

    logic [`N-1:0] btb_hit;
    WADDR [`N-1:0] btb_tgt;
    btb #(
        .QUERY_SZ(`N)
    ) btb0 (
        .clock,
        .reset,

        .i_qry,
        .o_vld(btb_hit),
        .o_tgt(btb_tgt),

        .i_upd
    );

    // logic ras_hit, ras_empty, full;
    // WADDR ras_rtgt, ras_wtgt;
    // ras #(
    //     .DEPTH(16)
    // ) ras0 (
    //     .clock,
    //     .reset,
    //     .flush,
    //     .flush_snap('0), // FIXME: need a snapshot table

    //     .empty(ras_empty)
    // );
    // assign ras_hit = !ras_empty;

    // stop fetching beyond the first predicted taken branch
    logic [`N-1:0] raw_take;
    assign raw_take = brch & btb_hit;

    // always_comb begin
    //     o_take = raw_take;
    //     for (int i = 1; i < `N; ++i)
    //         o_take[i] &= !o_take[i-1];
    // end

    logic take_any;
    logic [$clog2(`N)-1:0] take_idx;
    ffs #(
        .VECW(`N)
    ) ff_take (
        .i_vec(raw_take),
        .o_vld(take_any),
        .o_idx(take_idx)
    );

    assign o_take   = raw_take;
    assign o_lim_cnt= take_any ? take_idx + 1 : `N;
    assign o_tgt    = btb_tgt;
endmodule