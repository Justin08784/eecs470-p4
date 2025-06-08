`include "sys_defs.svh"

parameter FTQ_SZ = 32;
// FIXME: Isn't this just a FIFO?
module ftq #(
    parameter FTQ_SZ = FTQ_SZ,
    type PTR = logic [$clog2(FTQ_SZ)-1:0],
    type CNT = logic [$clog2(FTQ_SZ):0]
) (
    input   clock,
    input   reset,
    input   flush,

    // TODO: for fetch/decode-stage resteering/direct branch resolution
    // input   steer,
    // input   PTR         steer_tail,

    // bpu (pc generation)
    output  logic       rdy,
    input   logic       wen,
    input   FTQ_ENTRY   wdat,

    // fetch (icache read)
    output  logic       vld,
    output  FTQ_ENTRY   rdat,
    input   logic       ren
);
    PTR head, tail;
    FTQ_ENTRY [FTQ_SZ-1:0] state;
    CNT used;

    ring_ctr #(
        .DEPTH(FTQ_SZ),
        .WIDTH($bits(FTQ_ENTRY)),
        .RPORTS(1),
        .WPORTS(1),
        .FLUSH_MODE(FIFO_FLUSH_RESET)
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,
        .flush_snap ('0),

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

    assign vld  = used != 0;
    assign rdat = state[head];
    assign rdy  = used != FTQ_SZ;

    always_ff @(posedge clock) begin
        if (reset || flush)
            state <= '0;
        else begin
            if (wen)
                state[tail] <= wdat;
        end
    end


endmodule
