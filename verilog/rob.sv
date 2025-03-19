`include "sys_defs.svh"

module rob #(
    parameter ROB_SZ = `ROB_SZ,  // num elements
    parameter N=`N
) (
    `ifdef DEBUG
    output  ROB_ENTRY   [ROB_SZ-1:0]    state_dbg,
    `endif 
    input                       clock, reset, flush,

    // retire (read)
    output rob2retire r_out,

    // complete (write)
    input execute2complete c_in,

    // dispatch (write)
    output rob2dispatch d_out,

    input dispatch2rob d_in,

    output COMMIT_PACKET [`N-1:0] wb_packet,
    input PHYS_REG_IDX [`N-1:0] prf_in,
    output PHYS_REG_IDX [`N-1:0] prf_out
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
        r_out.r_free_cnt  = '0;
        r_out.tag       = '0;
        r_out.t_old     = '0;
        r_out.dst       = '0;
        wb_packet       = '0;
        for (int unsigned i = 0; i < NUM_RPORTS; ++i, ++r_out.r_en_cnt) begin
            // This computes r_en_cnt linear-time wrt NUM_RPORTS. (Fine if NUM_RPORTS
            // small; synthesizer may simply unroll this loop.)
            if (!state[r_idxs[i]].cpl)
                break;
            // if (i >= used)
            //     break;
            /*
            TODO [RESOLVED]: *IMPORTANT* retire zero_reg edge case!
            If the retiring insn has no real output register (e.g. hlt, store), then
            its destination will be the zero preg. You MUST NOT allow a zero preg
            to be added to the free list (this is causing the free_list FIFO
            overflow in the commit in which this comment was added.
            SHA: f24016e5a7d6a931ac32b72020fd154b3cfcc57c). 
            
            This presents a problem: our fifo.sv impl operates on counts, and assumes
            wr_data is contiguously filled from lowest indices. However, not all
            retiring insns with valid output pregs will be at the lowest indices
            (e.g. vld_preg_out? : [0, 1]). Two solutions for this:
            1. Form another intermediate N-wide array that compresses all retiring
            insns with valid output registers to the lowest indices, before sending
            it to free_list (a "packing loop" logic).

            e.g., In a 3-wide processor. retire stage sees:
              [0] -> valid, dst = 5
              [1] -> valid, dst = 0 (zero_reg - must skip!)
              [2] -> valid, dst = 6
            Must compress to [5, 6] before sending to free_list.

            2. Rewrite FIFO to accept valid buses instead of counts (however I believe
            lowest-index contiguity via counts offers performance advantages which
            other FIFOs like the decode or fetch FIFOs can, and *should*, exploit.)

            In addition, it seems 2 is only shifting the work of the "packing loop" into
            the FIFO (you still have to do it *somewhere*).
            */
            r_out.tag[i]    = state[r_idxs[i]].tag;
            if (state[r_idxs[i]].dst != `ZERO_REG) begin // pack all returning pregs to lowest indices
                r_out.t_old[r_out.r_free_cnt] = state[r_idxs[i]].t_old;
                ++r_out.r_free_cnt;
            end
            r_out.dst[i]    = state[r_idxs[i]].dst;
            r_out.brch_vld  = state[r_idxs[i]].is_brch;

            prf_out[i] = state[r_idxs[i]].tag;

            wb_packet[i] = '{
                NPC     : state[r_idxs[i]].NPC,
                data    : prf_in[i], //(mem_wb_reg.take_branch) ? mem_wb_reg.NPC : mem_wb_reg.result;
                reg_idx : state[r_idxs[i]].dst,
                halt    : state[r_idxs[i]].halt,
                illegal : state[r_idxs[i]].illegal,
                valid   : ~state[r_idxs[i]].illegal
            };

        end

        // handle dispatch (outs)
        /*
        TODO: This tradeoff needs consideration for performance
        Option 1: 
        d_out.rob_rdy_scnt = `MIN(free + r_out.r_en_cnt, NUM_DPORTS);
        + avoids dispatch stalls when ROB is full if N branches retire per cycle
        - longer combinational delay due to dependency on r_en_cnt

        Option 2: 
        d_out.rob_rdy_scnt = `MIN(free, NUM_DPORTS);
        (opposite of above points)
        */
        // The true number of same-cycle free slots is free + r_en_cnt
        d_out <= '{
            rob_rdy_scnt : `MIN(free + r_out.r_en_cnt, NUM_DPORTS),
            rob_idxs     : d_idxs
        };
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
            `ifndef SYNTH
            if (d_in.d_en_cnt > free + r_out.r_en_cnt)
                $error("ROB overflow!");
            if (r_out.r_en_cnt > used + d_in.d_en_cnt)
                $error("ROB underflow!");
            `endif
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
                state[cur_idx] <= '{
                    cpl     : 0,
                    is_brch : d_in.is_brch[i],
                    tag     : d_in.tag[i],
                    t_old   : d_in.t_old[i],
                    dst     : d_in.dst[i],
                    halt    : d_in.halt[i],
                    illegal : d_in.illegal[i],
                    NPC     : d_in.NPC[i]
                };
            end

            `ifndef SYNTH
            $display("  %3d | >> ROB", $time);
            $display("{r_free_cnt: %d, [(t: %0d, told: %0d, dst: %0d), (t: %0d, told: %0d, dst: %0d)]}",
                r_out.r_free_cnt,
                r_out.tag[0],
                r_out.t_old[0],
                r_out.dst[0],
                r_out.tag[1],
                r_out.t_old[1],
                r_out.dst[1]
            );
            $display("  %3d | << ROB", $time);
            `endif
        end
    end

endmodule
