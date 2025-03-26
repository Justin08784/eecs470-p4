`include "sys_defs.svh"

/*
TODO: I think there might need to be a retire module that interfaces with
both ROB and BTQ. Like if a retiring branch insn is mispredicted,
the rob insns after it should not be committed!

Maybe something that handles both rollback and retire?
*/

/* Branch target queue */
module btq #(
    parameter BTQ_SZ = `BTQ_SZ,  // num elements
    parameter N=`N
) (
    input clock, reset, flush,
    `ifdef DEBUG
    output BTQ_ENTRY [BTQ_SZ-1:0]   state_dbg,
    `endif 

    // retire (read & write)
    input  rob2retire r_in,
    output btq2fetch  f_out, // TODO: handling at fetch

    // complete (write)
    input  execute2complete c_in, // TODO: handling from EX

    // dispatch (write)
    input  dispatch2btq d_in,
    output btq2dispatch d_out
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)

    BTQ_ENTRY [BTQ_SZ-1:0]      state;
    logic [$clog2(BTQ_SZ)-1:0]  head;
    logic [$clog2(BTQ_SZ)-1:0]  tail;
    logic [$clog2(BTQ_SZ):0]    used;

    logic [$clog2(BTQ_SZ):0]    free;
    assign free         = BTQ_SZ - used;
    assign state_dbg    = state;

    logic [$clog2(NUM_DPORTS):0]    wr_cnt;
    logic [$clog2(NUM_RPORTS):0]    rd_cnt;
    assign wr_cnt = d_in.en_cnt;
    assign rd_cnt = $countones(r_in.brch_vld);

    logic [NUM_RPORTS-1:0][$clog2(BTQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(BTQ_SZ)-1:0] d_idxs;
    BTQ_ENTRY cur_entry;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % BTQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % BTQ_SZ;

        // handle fetch (outs)
        f_out = '0;
        for (int unsigned i = 0; i < NUM_RPORTS; ++i) begin
            cur_entry = state[r_idxs[i]];

            if (cur_entry.pred != cur_entry.take) begin
                f_out.mispred = 1;
                f_out.brch_tgt = cur_entry.tgt;
                break;
            end
        end

        // handle dispatch (outs)
        /*
        TODO: This tradeoff needs consideration for performance
        Option 1: 
        d_out.btq_rdy_scnt = `MIN(free + rd_cnt, NUM_DPORTS);
        + avoids dispatch stalls when BTQ is full if N branches retire per cycle
        - longer combinational delay due to dependency on rd_cnt

        Option 2: 
        d_out.btq_rdy_scnt = `MIN(free, NUM_DPORTS);
        (opposite of above points)
        */
        d_out = '{
            btq_rdy_scnt : `MIN(free, NUM_DPORTS),
            btq_idxs     : d_idxs
        };
    end

    always_ff @(posedge clock) begin
        if (reset || f_out.mispred) begin
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
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_CPORTS; ++i) begin
                if (!c_in.c_en[i])
                    continue;
                cur_idx = c_in.btq_idxs[i];

                state[cur_idx].tgt  <= c_in.tgts[i];
                state[cur_idx].take <= c_in.take[i];
            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= wr_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '0;
            end
        end
    end

endmodule
