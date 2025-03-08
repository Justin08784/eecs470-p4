`include "sys_defs.svh"

module rob #(
    parameter DEPTH = `ROB_SZ,  // num elements
    parameter WIDTH = $bits(ROB_ENTRY),  // num bits per element 
                           //(32 bits per insn + log2(64) = 6 bits each for T & Told)
    parameter N=`N
) (
    input                       clock, reset,

    // retire (read)
    output struct packed {
        logic [$clog2(N):0]     r_en_cnt;

        PHYS_REG_IDX [N-1:0]    tag;
        PHYS_REG_IDX [N-1:0]    t_old;
    } r_out,

    // complete (write)
    input struct packed {
        logic [N-1:0]           c_en;
            // - From: EX
        ROB_IDX [N-1:0]         c_rob_idxs;
            // - From: EX
    } c_in,

    // dispatch (write)
    output struct packed {
        logic [$clog2(N):0]     rob_rdy_scnt;
            // To: dispatch
            // saturating counter for number of free rob entries
    } d_out,
    input struct packed {
        logic [$clog2(N):0]     d_en_cnt;
            // From: dispatch
            // - Number of enabled dispatch lines?
        ROB_ENTRY   [N-1:0]     d_dat;
            // From: dispatch
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } d_in
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(DEPTH)-1:0]   head;
    logic [$clog2(DEPTH)-1:0]   tail;

    ROB_ENTRY [DEPTH-1:0]       state;
    logic [$clog2(DEPTH):0]     used, free;

    logic [NUM_RPORTS-1:0][$clog2(DEPTH)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(DEPTH)-1:0] d_idxs;

    assign free         = DEPTH - used;
    assign free_scnt    = free > NUM_DPORTS ? NUM_DPORTS : free;
    assign used_scnt    = used > NUM_RPORTS ? NUM_RPORTS : used;

    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % DEPTH;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % DEPTH;

        // handle retire (outs)
        r_out.r_en_cnt  = '0;
        r_out.tag       = '0;
        r_out.t_old     = '0;
        for (int unsigned i = 0; i < NUM_RPORTS; ++i, ++r_out.r_en_cnt) begin
            // This computes r_en_cnt linear-time wrt NUM_RPORTS. (Fine if NUM_RPORTS
            // small; synthesizer may simply unroll this loop.)
            if (!state[r_idxs[i]].cpl)
                break;
            r_out.tag[i]    = state[r_idxs[i]].tag;
            r_out.t_old[i]  = state[r_idxs[i]].t_old;
        end

        // handle dispatch (outs)
        // The true number of same-cycle free slots is free + r_en_cnt
        d_out.rob_rdy_scnt = `MIN(free + r_out.r_en_cnt, NUM_DPORTS);
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
            head    <= (head + r_out.r_en_cnt) % DEPTH;
            tail    <= (tail + d_in.d_en_cnt) % DEPTH;

            // handle complete (ins)
            for (int unsigned i = 0; i < NUM_CPORTS; ++i)
                state[c_in.c_rob_idxs[i]].cpl |= c_in.c_en[i];

            // handle dispatch (ins)
            for (int unsigned i = 0; i < NUM_DPORTS; ++i) begin
                if (i >= d_in.d_en_cnt)
                    continue;
                state[d_idxs[i]] <= d_in.d_dat[i];
            end
        end
    end

endmodule
