`include "sys_defs.svh"

// FIXME: Isn't this just a FIFO?
module ftq #(
    parameter FTQ_SZ = FTQ_SZ,
    type PTR = `IDX_TYPE(FTQ_SZ),
    type DPTR= `IDX_TYPE(2*FTQ_SZ),
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
    output  `CNT_TYPE(2)    vld_scnt,
    output  FTQ_ENTRY[1:0]  rdat,
    input   `CNT_TYPE(2)    ren_cnt
);
    DPTR head, tail;
    FTQ_ENTRY [FTQ_SZ-1:0] state;
    DPTR [2:0] rd_idxs_n;
    CNT used;

    ring_ctr #(
        .DEPTH      (FTQ_SZ),
        .RPORTS     (2),
        .WPORTS     (1),
        .FLUSH_MODE (FIFO_FLUSH_RESET)
    ) ring_ctr0 (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .flush_snap ('0),

        .rd_en_cnt  (ren_cnt),
        .wr_en_cnt  (wen),

        .head       (head),
        .tail       (tail),

        .rd_idxs_n  (rd_idxs_n),
        .wr_idxs_n  (),

        .used       (used),
        .free       (),
        .used_scnt  (vld_scnt),
        .free_scnt  ()
    );

    assign rdy = used != FTQ_SZ;
    for (genvar i = 0; i < 2; ++i)
        assign rdat[i] = state[PTR'(rd_idxs_n[i])];

    always_ff @(posedge clock) begin
        if (wen)
            state[PTR'(tail)] <= wdat;
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

            $display("ftq[%2d]: {base_n: %d} ft: %b, off: %d, md: %b",
                i,
                state[i].base_n,
                state[i].ft,
                state[i].off,
                state[i].md
            );
        end

        $display("<< FTQ <<");
    endtask

`endif

endmodule
