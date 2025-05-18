`include "sys_defs.svh"

/* Branch target queue */
module btq #(
    parameter BTQ_SZ = `BTQ_SZ,  // num elements
    parameter N=`N
) (
    input  clock,
    input  reset,
    input  flush,
    input  BMASK clmsk,

    // retire
    input  retire2btq   r_in,
    output btq2retire   r_out,

    // complete (write)
    input  execute2btq  ex_in,
    output btq2execute  ex_out,

    // dispatch (alloc snapshot)
    input  rename2snap_bus snap_in,

    // fetch
    input  fetch2btq    f_in,
    output btq2fetch    f_out
);
    localparam NUM_FPORTS = N; // fetch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = `NUM_FU_BRU; // complete ports (*OUT-OF-ORDER*)

    BTQ_ENTRY [BTQ_SZ-1:0]      state;
    logic [$clog2(BTQ_SZ)-1:0]  head;
    logic [$clog2(BTQ_SZ)-1:0]  tail;
    logic [$clog2(BTQ_SZ)-1:0]  snap;
    logic [$clog2(BTQ_SZ):0]    used;
    logic [$clog2(BTQ_SZ):0]    free;

    logic [NUM_RPORTS:0][$clog2(BTQ_SZ)-1:0] r_idxs_n;
    logic [NUM_FPORTS:0][$clog2(BTQ_SZ)-1:0] f_idxs_n;

    ring_ctr #(
        .DEPTH(BTQ_SZ),
        .WIDTH($bits(BTQ_ENTRY)),
        .RPORTS(NUM_RPORTS),
        .WPORTS(NUM_FPORTS),
        .FLUSH_MODE(FIFO_FLUSH_SNAP_TAIL)
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,
        .flush_snap (snap),

        .rd_en_cnt  (r_in.rd_cnt),
        .wr_en_cnt  (f_in.en_cnt),

        .head,
        .tail,
        .rd_idxs_n  (r_idxs_n),
        .wr_idxs_n  (f_idxs_n),

        .used,
        .free,
        .used_scnt(),
        .free_scnt(f_out.btq_rdy_scnt)
    );

    general_snaps #(
        .WIDTH($clog2(`BTQ_SZ))
    ) btq_tails (
        .clock,

        .rmsk   (clmsk),
        .rdat   (snap),

        .wen    (snap_in.snap_en),
        .wmsk   (snap_in.b1hot_n),
        .wdat   (snap_in.btq_tail)
    );

    logic puq_empty;
    PUQ_ENTRY [NUM_RPORTS-1:0] tmp_puq_in;
    always_comb begin
        // handle fetch (outs)
        for (int i = 0; i < NUM_RPORTS; ++i) begin
            tmp_puq_in[i].take = state[r_idxs_n[i]].take;
            tmp_puq_in[i].pc   = state[r_idxs_n[i]].PC;
            tmp_puq_in[i].tgt  = state[r_idxs_n[i]].tgt;
        end

        f_out.puq_en = !puq_empty;
        f_out.btq_idxs_n     = f_idxs_n;

        // handle reads (execute)
        for (int i = 0; i < `NUM_FU_BRU; ++i) begin
            int idx;
            idx = ex_in.btq_idx[i];
            ex_out.pred[i]     = state[idx].pred;
            ex_out.pred_tgt[i] = state[idx].pred_tgt;
        end
    end

    localparam PUQ_SZ = 3;
    fifo #(
        .DEPTH(PUQ_SZ),
        .WIDTH($bits(PUQ_ENTRY)),
        .NUM_RPORTS(1),
        .NUM_WPORTS(NUM_RPORTS),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) puq ( // predictor update queue
        .clock      (clock),
        .reset      (reset),
        .flush      ('0),
        .wr_en_cnt  (r_in.rd_cnt),
        .wr_data    (tmp_puq_in),
        .rd_en_cnt  (f_out.puq_en),
        .rd_data    (f_out.puq_dat),
        .free_scnt  (r_out.puq_rdy_scnt),
        .used_scnt  (),
        .empty      (puq_empty)
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            state   <= '0;
        end else begin
            if (f_in.en_cnt > free)
                $error("BTQ overflow!");
            if (r_in.rd_cnt > used)
                $error("BTQ underflow!");

            // handle complete (ins)
            for (int i = 0, int idx = 0; i < NUM_CPORTS; ++i) begin
                idx = ex_in.dat[i].btq_idx;
                if (!ex_in.dat[i].en)
                    continue;

                state[idx].tgt  <= ex_in.dat[i].tgt;
                state[idx].take <= ex_in.dat[i].take;
`ifdef DEBUG
                state[idx].b1hot<= '0;
`endif
            end

`ifdef DEBUG
            // mark alloc'd b1hot (debug only)
            for (int i = 0; i < N; ++i) begin
                if (!snap_in.snap_en[i])
                    continue;
                state[snap_in.btq_idx[i]].b1hot <= snap_in.b1hot_n[i];
            end
`endif

            // handle fetch (ins)
            for (int i = 0, int idx = 0; i < NUM_FPORTS; ++i) begin
                idx = f_idxs_n[i];
                if (i >= f_in.en_cnt)
                    continue;

                state[idx] <= '{
`ifdef DEBUG
                    b1hot   : '0,
`endif
                    PC      : f_in.PC[i],
                    pred    : f_in.pred[i],
                    pred_tgt: f_in.pred_tgt[i],

                    take    : '0,
                    tgt     : '0
                };
            end
        end
    end

`ifdef DEBUG
    task print_btq;
        logic [BTQ_SZ-1:0] btq_vld;

        $display(">> BTQ >>");
        $display("head: %d, tail: %d, used: %d, free: %d", head, tail, used, free);
        $display("flush: %b, flush_snap: %2d", flush, snap);
        $display("rd_en_cnt: %2d, wr_en_cnt: %2d", r_in.rd_cnt, f_in.en_cnt);
        btq_vld = '0;
        for (int cnt = 0; cnt < used; ++cnt)
            btq_vld[(head + cnt) % BTQ_SZ] = 1;

        for (int i = 0; i < BTQ_SZ; ++i) begin
            if (!btq_vld[i]) begin
                $display("BTQ[%2d]:", i);
                continue;
            end

            $write("BTQ[%2d]: pred: %b, pred_tgt: %x, take: %b, tgt: %x, ",
                i,
                state[i].pred,
                state[i].pred_tgt,
                state[i].take,
                state[i].tgt
            );

            if(|state[i].b1hot)
                $display("b1hot: %b", state[i].b1hot);
            else
                $display("b1hot:");
        end

        for (int i = 0; i < `NUM_FU_BRU; ++i) begin
            $display("ex_in[%0d]: en: %b, btq_idx: %d, take: %b, tgt: %x",
                i,
                ex_in.dat[i].en,
                ex_in.dat[i].btq_idx,
                ex_in.dat[i].take,
                ex_in.dat[i].tgt
            );
        end

        $display("r_in: rd_cnt %d", r_in.rd_cnt);
        $display("<< BTQ <<");
    endtask

`endif

endmodule
