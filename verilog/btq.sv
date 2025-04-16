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
    `ifdef DEBUG
    output DBG_btq dbg,
    `endif 
    input clock, reset, flush,

    // retire
    input  retire2btq       r_in,
    output btq2retire       r_out,

    // complete (write)
    input  execute2complete_dat cdat_in,

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

    logic [$clog2(NUM_DPORTS):0]    wr_cnt;
    logic [$clog2(NUM_RPORTS):0]    rd_cnt;
    assign wr_cnt = d_in.en_cnt;
    assign rd_cnt = r_in.rd_cnt;

    logic [NUM_RPORTS-1:0][$clog2(BTQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(BTQ_SZ)-1:0] d_idxs;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % BTQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
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
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_CPORTS; ++i) begin
                if (!cdat_in.en[i] || !cdat_in.is_brch[i])
                    continue;
                cur_idx = cdat_in.btq_idxs[i];

                state[cur_idx].tgt  <= cdat_in.data[i];
                state[cur_idx].take <= cdat_in.take[i];
            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= wr_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    tgt     : '0,
                    NPC     : d_in.NPC[i],
                    // TODO: pred and take need to be set by fetch! I think?
                    pred    : d_in.pred[i],
                    take    : '0,
                    PC      : d_in.PC[i],
                    bhr     : d_in.bhr[i],
                    correlated_bhr : d_in.correlated_bhr[i],

                    gshare_pred : d_in.gshare_pred[i],
                    corr_pred   : d_in.corr_pred[i]
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
        cdat_in,
        d_in,
        d_out
    };
    `endif

endmodule
