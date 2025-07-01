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
    output  `CNT_TYPE(2)    vld_scnt,
    output  FTQ_ENTRY[1:0]  rdat,
    input   `CNT_TYPE(2)    ren_cnt
);
    PTR head, tail;
    FTQ_ENTRY [FTQ_SZ-1:0] state;
    PTR [2:0] rd_idxs_n;
    CNT used;

    ring_ctr #(
        .DEPTH(FTQ_SZ),
        .RPORTS(2),
        .WPORTS(1),
        .FLUSH_MODE(FIFO_FLUSH_RESET)
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,
        .flush_snap ('0),

        .rd_en_cnt  (ren_cnt),
        .wr_en_cnt  (wen),

        .head,
        .tail,

        .rd_idxs_n,
        .wr_idxs_n  (),

        .used,
        .free       (),
        .used_scnt  (vld_scnt),
        .free_scnt  ()
    );

    generate
    assign rdy = used != FTQ_SZ;
    for (genvar i = 0; i < 2; ++i) begin
        assign rdat[i] = state[rd_idxs_n[i]];
    end
    endgenerate

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
