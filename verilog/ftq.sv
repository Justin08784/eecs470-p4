`include "sys_defs.svh"

// FIXME: Isn't this just a FIFO?
module ftq #(
    parameter FTQ_SZ = FTQ_SZ,
    type PTR = `IDX_TYPE(FTQ_SZ),
    type CNT = `CNT_TYPE(FTQ_SZ)
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

`ifdef DEBUG
    task print_ftq;
        logic [FTQ_SZ-1:0] ftq_vld;

        $display(">> FTQ >>");
        $display("head: %d, tail: %d, used: %d", head, tail, used);
        // $display("flush: %b, flush_snap: %2d, clmsk: %b", flush, snap, clmsk);

        ftq_vld = '0;
        for (int cnt = 0; cnt < used; ++cnt)
            ftq_vld[(head + cnt) % FTQ_SZ] = 1;

        for (int i = 0; i < FTQ_SZ; ++i) begin
            if (!ftq_vld[i]) begin
                $display("ftq[%2d]:", i);
                continue;
            end

            $display("ftq[%2d]: {base_n: %d} vld: %b, ft: %b, off: %b, always_take: %b, md: %b",
                i,
                state[i].base_n,
                state[i].vld,
                state[i].ft,
                state[i].off,
                state[i].always_take,
                state[i].md
            );
        end

        $display("<< FTQ <<");
    endtask

`endif


endmodule
