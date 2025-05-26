`include "sys_defs.svh"

module ftq #(
    parameter FTQ_SZ = `FTQ_SZ, // num elements
    type PTR = logic [$clog2(FTQ_SZ)-1:0],
    type CNT = logic [$clog2(FTQ_SZ):0]
) (
    input   clock,
    input   reset,
    input   flush,

    input   steer,
    input   PTR         steer_tail,
    input   FTQ_ENTRY   sdat,

    // if1 (pc generation)
    input   logic       wen,
    input   FTB_ENTRY   wdat,
    output  logic       full,
    output  PTR         tail,

    // if2 (icache read)
    input   logic       ren,
    output  FTQ_ENTRY   rdat,
    output  logic       empty
);
    PTR head;
    FTQ_ENTRY [FTQ_SZ-1:0] state;
    CNT used;

    ring_ctr #(
        .DEPTH(FTQ_SZ),
        .WIDTH($bits(FTQ_ENTRY)),
        .RPORTS(1),
        .WPORTS(1),
        .FLUSH_MODE(FIFO_FLUSH_SNAP_TAIL)
    ) ring_ctr0 (
        .clock,
        .reset      (reset || flush),
        .flush      (steer),
        .flush_snap (steer_tail + 1),

        .rd_en_cnt  (ren),
        .wr_en_cnt  (wen),

        .head,
        .tail,

        .rd_idxs_n  (),
        .wr_idxs_n  (),

        .used,
        .free       (),
        .used_scnt  (),
        .free_scnt  ()
    );

    assign rdat = state[head];
    assign full = used == FTQ_SZ;
    assign empty= used == 0;

    always_ff @(posedge clock) begin
        if (reset)
            state <= '0;
        else if (steer)
            state[steer_tail] <= sdat;
        else if (wen)
            state[tail] <= wdat;
    end


endmodule
