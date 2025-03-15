`include "sys_defs.svh"

module rob #(
    parameter ROB_SZ = `ROB_SZ,  // num elements
    parameter N=`N
) (
    `ifdef DEBUG
    output  ROB_ENTRY   [ROB_SZ-1:0]    state_dbg,
    `endif 
    input                       clock, reset,

    // retire (read)
    output rob2retire r_out,

    // complete (write)
    input complete2rob c_in,

    // dispatch (write)
    output rob2dispatch d_out,

    input dispatch2rob d_in
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(ROB_SZ)-1:0]   head;
    logic [$clog2(ROB_SZ)-1:0]   tail;

    ROB_ENTRY [ROB_SZ-1:0]       state;
    logic [$clog2(ROB_SZ):0]     used, free;

    logic [NUM_RPORTS-1:0][$clog2(ROB_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(ROB_SZ)-1:0] d_idxs;

    assign state_dbg    = state;
    assign free         = ROB_SZ - used;
    assign free_scnt    = free > NUM_DPORTS ? NUM_DPORTS : free;
    assign used_scnt    = used > NUM_RPORTS ? NUM_RPORTS : used;

    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % ROB_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % ROB_SZ;

        // handle retire (outs)
        r_out.r_en_cnt  = '0;
        r_out.tag       = '0;
        r_out.t_old     = '0;
        for (int unsigned i = 0; i < NUM_RPORTS; ++i, ++r_out.r_en_cnt) begin
            // This computes r_en_cnt linear-time wrt NUM_RPORTS. (Fine if NUM_RPORTS
            // small; synthesizer may simply unroll this loop.)
            if (!state[r_idxs[i]].cpl)
                break;
            // if (i >= used)
            //     break;
            r_out.tag[i]    = state[r_idxs[i]].tag;
            r_out.t_old[i]  = state[r_idxs[i]].t_old;
        end

        // handle dispatch (outs)
        // The true number of same-cycle free slots is free + r_en_cnt
        d_out.rob_rdy_scnt = `MIN(free + r_out.r_en_cnt, NUM_DPORTS);
        d_out.rob_idxs     = d_idxs;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            state   <= '0;
            // used    <= RESET_STATE.used;
            // head    <= RESET_STATE.head;
            // tail    <= RESET_STATE.tail;
            // state   <= RESET_STATE.state;
        end else begin
            if (d_in.d_en_cnt > free + r_out.r_en_cnt)
                $error("ROB overflow!");
            if (r_out.r_en_cnt > used + d_in.d_en_cnt)
                $error("ROB underflow!");
            used    <= used + d_in.d_en_cnt - r_out.r_en_cnt;
            head    <= (head + r_out.r_en_cnt) % ROB_SZ;
            tail    <= (tail + d_in.d_en_cnt) % ROB_SZ;

            // handle complete (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_CPORTS; ++i) begin
                cur_idx = c_in.c_rob_idxs[i];
                // $display("c[%d]: (en: %b, idx: %d), state[%d].cpl: %b, c_in.c_en[i]: %b, or: %b...",
                //     i,
                //     c_in.c_en[i],
                //     c_in.c_rob_idxs[i],
                //     cur_idx,
                //     state[cur_idx].cpl,
                //     c_in.c_en[i],
                //     state[cur_idx].cpl | c_in.c_en[i]
                // );

                /* V1: This doesn't actually update the cpl bit... */
                // state[cur_idx].cpl <= state[cur_idx].cpl | c_in.c_en[i];
                /* V2: ...but this one does???! Make this make sense? */
                if (c_in.c_en[i])
                    state[cur_idx].cpl <= 1;
            end

            // handle dispatch (ins)
            // $display("d_en_cnt: %d", d_in.d_en_cnt);
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                // $display("d[%d]: (tag: %d, t_old: %d, idx: %d)", i, d_idxs[i], d_in.tag[i], d_in.t_old[i]);
                if (i >= d_in.d_en_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx].tag    <= d_in.tag[i];
                state[cur_idx].t_old  <= d_in.t_old[i];
            end
        end
    end

endmodule
