`include "sys_defs.svh"

/* Branch target queue */
module btq #(
    parameter BTQ_SZ = `BTQ_SZ,  // num elements
    parameter N=`N
) (
    input  clock,
    input  reset,
    input  flush,

    // retire
    input  retire2btq   r_in,
    output btq2retire   r_out,

    // complete (write)
    input  execute2btq  ex_in,

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
    logic [$clog2(BTQ_SZ):0]    used;
    logic [$clog2(BTQ_SZ):0]    free;

    logic [NUM_RPORTS-1:0][$clog2(BTQ_SZ)-1:0] r_idxs;
    logic [NUM_FPORTS-1:0][$clog2(BTQ_SZ)-1:0] f_idxs;

    ring_ctr #(
        .DEPTH(BTQ_SZ),
        .WIDTH($bits(BTQ_ENTRY)),
        .RPORTS(NUM_RPORTS),
        .WPORTS(NUM_FPORTS),
        .FLUSH_MODE(FIFO_FLUSH_RESET)
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,
        .flush_tail ('0),

        .rd_en_cnt  (r_in.rd_cnt),
        .wr_en_cnt  (f_in.en_cnt),

        .head,
        .tail,
        .rd_idxs    (r_idxs),
        .wr_idxs    (f_idxs),

        .used,
        .free,
        .used_scnt(),
        .free_scnt(f_out.btq_rdy_scnt)
    );

    always_comb begin
        // handle retire (outs)
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_out.dat[i] = state[r_idxs[i]];

        // handle fetch (outs)
        f_out.btq_idxs     = f_idxs;
    end

    logic puq_empty;
    PUQ_ENTRY [NUM_RPORTS-1:0] tmp_puq_in;
    always_comb begin
        for (int i = 0; i < NUM_RPORTS; ++i) begin
            tmp_puq_in[i].take = state[r_idxs[i]].take;
            tmp_puq_in[i].pc   = state[r_idxs[i]].PC;
            tmp_puq_in[i].tgt  = state[r_idxs[i]].tgt;
        end

        f_out.puq_en = !puq_empty;
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
        if (reset || flush) begin
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
            end

            // handle fetch (ins)
            for (int i = 0, int idx = 0; i < NUM_FPORTS; ++i) begin
                idx = f_idxs[i];
                if (i >= f_in.en_cnt)
                    continue;

                state[idx] <= '{
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
        $display(">> BTQ >>");
        for (int i = 0; i < `BTQ_SZ; ++i) begin
            $display("BTQ [%0d]: tgt: %x, pred: %b, take: %b%s",
                i,
                state[i].tgt,
                state[i].pred,
                state[i].take,
                (i == head && head == tail) 
                    ? " << h/t"
                    : (i == head) 
                        ? " << h" 
                        : (i == tail)
                            ? " << t"
                            : ""
            );
            if (i == tail)
                break;
        end

        for (int i = 0; i < `N; ++i) begin
            $display("ex_in[%0d]: en: %b, btq_idx: %d, take: %b, tgt: %x",
                i,
                ex_in.dat[i].en,
                ex_in.dat[i].btq_idx,
                ex_in.dat[i].take,
                ex_in.dat[i].tgt
            );
        end
        $display("r_in: rd_cnt %d", r_in.rd_cnt);
        for (int i = 0; i < `N; ++i) begin
            $display("r_out[%d]: tgt: %x, pred: %b, take: %b",
                i,
                r_out.dat[i].tgt,
                r_out.dat[i].pred,
                r_out.dat[i].take
            );
        end
        $display("<< BTQ <<");
    endtask

`endif

endmodule
