
module bp #(parameter
    QUERY_SZ // i.e. number of branch slots, BTB read slots
    // UPD_SZ    = BP_UPD_SZ
) (
    input   clock,
    input   reset,

    // fetch npc query
    input   WADDR   [QUERY_SZ-1:0]  i_qry, // branch pc

    output  logic   [QUERY_SZ-1:0]  o_take,
    output  WADDR   [QUERY_SZ-1:0]  o_tgt,

    // puq updates
    input   puq2fetch i_upd
);

    logic [QUERY_SZ-1:0] btb_hit;
    WADDR [QUERY_SZ-1:0] btb_tgt;
    btb #(
        .QUERY_SZ(QUERY_SZ)
    ) btb0 (
        .clock,
        .reset,

        .i_qry,
        .o_vld(btb_hit),
        .o_tgt(btb_tgt),

        .i_upd
    );

    assign o_take = btb_hit;
    assign o_tgt  = btb_tgt;
endmodule