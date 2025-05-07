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

    // fetch
    input  fetch2btq f_in,
    output btq2fetch f_out,

    // retire
    input  retire2btq   r_in,
    output btq2retire   r_out,

    // complete (write)
    input  execute2btq  ex_in
);
    localparam NUM_FPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = `NUM_FU_ALU; // complete ports (*OUT-OF-ORDER*)

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
    logic [NUM_FPORTS-1:0][$clog2(BTQ_SZ)-1:0] d_idxs;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % BTQ_SZ;
        for (int unsigned i = 0; i < NUM_FPORTS; ++i)
            d_idxs[i] = (tail + i) % BTQ_SZ;

        // handle retire (outs)
        r_out = '0;
        r_out.used_scnt = `MIN(used, NUM_RPORTS);
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_out.dat[i] = state[r_idxs[i]];

        // handle dispatch (outs)
        /*
        TODO: This tradeoff needs consideration for performance
        Option 1: 
        d_out.rdy_scnt = `MIN(free + rd_cnt, NUM_FPORTS);
        + avoids dispatch stalls when BTQ is full if N branches retire per cycle
        - longer combinational delay due to dependency on rd_cnt

        Option 2: 
        d_out.rdy_scnt = `MIN(free, NUM_FPORTS);
        (opposite of above points)
        */
        f_out = '{
            rdy_scnt    : `MIN(free, NUM_FPORTS),
            btq_idxs    : d_idxs
        };
    end

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

            // handle dispatch (ins)
            for (int i = 0, int idx = 0; i < NUM_FPORTS; ++i) begin
                idx = d_idxs[i];
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
        ex_in,
        d_in,
        d_out
    };
`endif

endmodule
