`include "sys_defs.svh"

/* Branch target queue */
module btq #(
    parameter BTQ_SZ = `BTQ_SZ,  // num elements
    parameter N=`N
) (
`ifdef DEBUG
    output DBG_btq dbg,
`endif 
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
    assign free = BTQ_SZ - used;

    logic [$clog2(NUM_FPORTS):0]    wr_cnt;
    logic [$clog2(NUM_RPORTS):0]    rd_cnt;
    assign wr_cnt = f_in.en_cnt;
    assign rd_cnt = r_in.rd_cnt;

    logic [NUM_RPORTS-1:0][$clog2(BTQ_SZ)-1:0] r_idxs;
    logic [NUM_FPORTS-1:0][$clog2(BTQ_SZ)-1:0] f_idxs;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % BTQ_SZ;
        for (int unsigned i = 0; i < NUM_FPORTS; ++i)
            f_idxs[i] = (tail + i) % BTQ_SZ;

        // handle retire (outs)
        r_out.btq_used_scnt = `MIN(used, NUM_RPORTS);
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_out.dat[i] = state[r_idxs[i]];

        // handle fetch (outs)
        /*
        TODO: This tradeoff needs consideration for performance
        Option 1: 
        f_out.btq_rdy_scnt = `MIN(free + rd_cnt, NUM_FPORTS);
        + avoids fetch stalls when BTQ is full if N branches retire per cycle
        - longer combinational delay due to dependency on rd_cnt

        Option 2: 
        f_out.btq_rdy_scnt = `MIN(free, NUM_FPORTS);
        (opposite of above points)
        */
        f_out.btq_rdy_scnt = `MIN(free, NUM_FPORTS);
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
        .wr_en_cnt  (rd_cnt),
        .wr_data    (tmp_puq_in),
        .rd_en_cnt  (f_out.puq_en),
        .rd_data    (f_out.puq_dat),
        .free_scnt  (r_out.puq_rdy_scnt),
        .used_scnt  (),
        .empty      (puq_empty)
    );

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            state   <= '0;
        end else begin
            if (wr_cnt > free)
                $error("BTQ overflow!");
            if (rd_cnt > used)
                $error("BTQ underflow!");
            used    <= used + wr_cnt - rd_cnt;
            head    <= (head + rd_cnt) % BTQ_SZ;
            tail    <= (tail + wr_cnt) % BTQ_SZ;

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
                if (i >= wr_cnt)
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
    assign dbg = '{
        state,
        head,
        tail,
        used,
        r_in,
        r_out,
        ex_in
    };
`endif

endmodule
