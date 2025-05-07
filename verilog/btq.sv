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
    logic [NUM_FPORTS-1:0][$clog2(BTQ_SZ)-1:0] f_idxs;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % BTQ_SZ;
        for (int unsigned i = 0; i < NUM_FPORTS; ++i)
            f_idxs[i] = (tail + i) % BTQ_SZ;

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
            btq_idxs    : f_idxs
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
        ex_in,
        d_in,
        d_out
    };
`endif

endmodule

// Split queue design (did not help timing)

// `include "sys_defs.svh"
// 
// /* Branch target queue */
// module btq #(
//     parameter BTQ_SZ = `BTQ_SZ,  // num elements
//     parameter N=`N
// ) (
// `ifdef DEBUG
//     output DBG_btq dbg,
// `endif 
//     input  clock,
//     input  reset,
//     input  flush,
// 
//     // fetch
//     input  fetch2btq f_in,
//     output btq2fetch f_out,
// 
//     // retire
//     input  retire2btq   r_in,
//     output btq2retire   r_out,
// 
//     // complete (write)
//     input  execute2btq  ex_in
// );
//     localparam NUM_FPORTS = N; // dispatch ports (in-order)
//     localparam NUM_RPORTS = N; // retire ports (in-order)
//     localparam NUM_CPORTS = `NUM_FU_ALU; // complete ports (*OUT-OF-ORDER*)
// 
//     /* Intermediate buffers */
//     fetch2btq   w2r_pipe;
//     retire2btq  r2w_pipe;
//     always_ff @(posedge clock) begin
//         if (reset || flush) begin
//             r2w_pipe    <= '0;
//             w2r_pipe    <= '0;
//         end else begin
//             r2w_pipe    <= r_in;
//             w2r_pipe    <= f_in;
//         end
//     end
// 
//     /* Write "queue" */
//     logic [$clog2(BTQ_SZ)-1:0]  wq_tail;
//     logic [$clog2(BTQ_SZ):0]    wq_free;
//     logic [$clog2(NUM_RPORTS):0]    wr_cnt;
//     assign wr_cnt = f_in.en_cnt;
// 
//     always_comb begin
//         logic [NUM_FPORTS-1:0][$clog2(BTQ_SZ)-1:0] wq_f_idxs;
// 
//         for (int i = 0; i < NUM_FPORTS; ++i)
//             wq_f_idxs[i] = (wq_tail + i) % BTQ_SZ;
// 
//         // handle fetch (outs)
//         f_out = '{
//             rdy_scnt    : `MIN(wq_free, NUM_FPORTS),
//             btq_idxs    : wq_f_idxs
//         };
//     end
// 
//     always_ff @(posedge clock) begin
//         if (reset || flush) begin
//             wq_tail     <= '0;
//             wq_free     <= BTQ_SZ;
//         end else begin
//             if (wr_cnt > wq_free)
//                 $error("BTQ overflow!");
//             wq_tail     <= (wq_tail + wr_cnt) % BTQ_SZ;
//             wq_free     <= wq_free  + r2w_pipe.rd_cnt - wr_cnt;
//         end
//     end
// 
// 
//     /* Read queue */
//     BTQ_ENTRY [BTQ_SZ-1:0]      state;
//     logic [$clog2(BTQ_SZ)-1:0]  head;
//     logic [$clog2(BTQ_SZ)-1:0]  tail;
//     logic [$clog2(BTQ_SZ):0]    used;
//     logic [$clog2(NUM_RPORTS):0]    rd_cnt;
//     assign rd_cnt = r_in.rd_cnt;
// 
//     logic [NUM_FPORTS-1:0][$clog2(BTQ_SZ)-1:0] f_idxs;
//     logic [NUM_RPORTS-1:0][$clog2(BTQ_SZ)-1:0] r_idxs;
//     always_comb begin
//         for (int i = 0; i < NUM_FPORTS; ++i)
//             f_idxs[i] = (tail + i) % BTQ_SZ;
//         for (int i = 0; i < NUM_RPORTS; ++i)
//             r_idxs[i] = (head + i) % BTQ_SZ;
// 
//         // handle retire (outs)
//         r_out = '0;
//         r_out.used_scnt = `MIN(used, NUM_RPORTS);
//         for (int i = 0; i < NUM_RPORTS; ++i)
//             r_out.dat[i] = state[r_idxs[i]];
//     end
// 
//     always_ff @(posedge clock) begin
//         if (reset || flush) begin
//             used    <= 0;
//             head    <= 0;
//             tail    <= 0;
//             state   <= '0;
//         end else begin
//             if (rd_cnt > used)
//                 $error("BTQ underflow!");
//             used    <= used + w2r_pipe.en_cnt - rd_cnt;
//             head    <= (head + rd_cnt) % BTQ_SZ;
//             tail    <= (tail + w2r_pipe.en_cnt) % BTQ_SZ;
// 
//             // handle complete (ins)
//             for (int i = 0, int idx = 0; i < NUM_CPORTS; ++i) begin
//                 idx = ex_in.dat[i].btq_idx;
//                 if (!ex_in.dat[i].en)
//                     continue;
// 
//                 state[idx].tgt  <= ex_in.dat[i].tgt;
//                 state[idx].take <= ex_in.dat[i].take;
//             end
// 
//             // handle fetch (ins)
//             for (int i = 0, int idx = 0; i < NUM_FPORTS; ++i) begin
//                 idx = f_idxs[i];
//                 if (i >= w2r_pipe.en_cnt)
//                     continue;
// 
//                 state[idx] <= '{
//                     PC      : w2r_pipe.PC[i],
//                     pred    : w2r_pipe.pred[i],
//                     pred_tgt: w2r_pipe.pred_tgt[i],
// 
//                     take    : '0,
//                     tgt     : '0
//                 };
//             end
//         end
//     end
// 
// `ifdef DEBUG
//     assign dbg = '{
//         state,
//         head,
//         tail,
//         used,
//         r_in,
//         r_out,
//         ex_in,
//         d_in,
//         d_out
//     };
// `endif

