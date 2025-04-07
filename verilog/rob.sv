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
    input  retire_final r_in,

    // complete (write)
    input  execute2complete_dat cdat_in,

    // dispatch (write)
    output rob2dispatch d_out,
    input  dispatch2rob d_in,

    //SQ
    input  sq2retire sq_in,
    output rob2sq sq_out
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(ROB_SZ)-1:0]  head;
    logic [$clog2(ROB_SZ)-1:0]  tail;

    ROB_ENTRY [ROB_SZ-1:0]      state;
    logic [$clog2(ROB_SZ):0]    used, free;
    logic [$clog2(4*`N):0]      rsvd;
    /*
    FIXME: can just make rsvd [$clog2(ROB_SZ):0] to be safe but I'm trying to
    match it exactly with the max number of insns that can have reservations:
    sz(alloc_buf) + sz(rename_buf) = 4*`N.
    */

    logic [NUM_RPORTS-1:0][$clog2(ROB_SZ)-1:0] rtre_idxs;
    logic [NUM_DPORTS-1:0][$clog2(ROB_SZ)-1:0] comm_idxs;

    assign state_dbg    = state;
    assign free_scnt    = `MIN(free - rsvd, NUM_DPORTS);
    assign used_scnt    = `MIN(used, NUM_RPORTS);

    always_comb begin
        sq_out = '0;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            rtre_idxs[i] = (head + i) % ROB_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            comm_idxs[i] = (tail + i) % ROB_SZ;

        // handle retire (outs)
        r_out.r_vld_cnt = used_scnt;
        for (int unsigned i = 0; i < used_scnt; ++i) begin
            /* preview mode–– just display all valid entries in read window even
            if not all will get retired this cycle */
            r_out.entries[i] = state[rtre_idxs[i]];

            //tell SQ to retire entries
            // if (state[rtre_idxs[i]].wr_mem)
            //     ++sq_out.r_en;
        end

        // handle dispatch (outs)
        /*
        TODO: This tradeoff needs consideration for performance
        Option 1: 
        d_out.rob_rdy_scnt = `MIN(free + r_out.r_vld_cnt, NUM_DPORTS);
        + avoids dispatch stalls when ROB is full if N branches retire per cycle
        - longer combinational delay due to dependency on r_en_cnt

        Option 2: 
        d_out.rob_rdy_scnt = `MIN(free, NUM_DPORTS);
        (opposite of above points)
        */
        // The true number of same-cycle free slots is free + r_en_cnt
        d_out = '{
            // rob_rdy_scnt : `MIN(free + r_out.r_vld_cnt, NUM_DPORTS),
            rob_rdy_scnt : free_scnt,
            rob_idxs     : comm_idxs
        };
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            free    <= ROB_SZ;
            rsvd    <= 0;

            head    <= 0;
            tail    <= 0;
            state   <= '0;
        end else begin
            `ifndef SYNTH
            if (d_in.d_en_cnt > free + r_out.r_vld_cnt)
                $error("ROB overflow!");
            if (r_out.r_vld_cnt > used + d_in.d_en_cnt)
                $error("ROB underflow!");
            `endif
            used    <= used + d_in.d_en_cnt - r_in.r_en_cnt;
            free    <= free - d_in.d_en_cnt + r_in.r_en_cnt;
            rsvd    <= rsvd - d_in.d_en_cnt + d_in.alloc_en_cnt;
            head    <= (head + r_in.r_en_cnt) % ROB_SZ;
            tail    <= (tail + d_in.d_en_cnt) % ROB_SZ;

            // handle complete (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_CPORTS; ++i) begin
                cur_idx = cdat_in.rob_idxs[i];

                /* V1: This doesn't actually update the cpl bit... */
                // state[cur_idx].cpl <= state[cur_idx].cpl || cdat_in.en[i];
                /* V2: ...but this one does???! Make this make sense? */
                if (cdat_in.en[i])
                    state[cur_idx].cpl <= 1;
                /*
                V1 is incorrect due to the following edge case:
                If the same `rob_idx`appears multiple times in the CDB (e.g., [0, 0]),
                and only the first entry has `c_en[i] == 1`, the second will
                overwrite the intended update.
                
                For example: c_rob_idxs = [0, 0], c_en = [1, 0]
                  - i = 0: state[0].cpl <= 0 || 1 -> schedules state[0].cpl = 1
                  - i = 1: state[0].cpl <= 0 || 0 -> *overwrites* with state[0].cpl = 0
                
                This edge case seems only possible (as far as we can tell) for rob_idx 0,
                since the CDB defaults to 0 at the start of each cycle.
                */
            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= d_in.d_en_cnt)
                    continue;
                cur_idx = comm_idxs[i];
                state[cur_idx] <= '{
                    cpl     : 0,
                    is_brch : d_in.is_brch[i],
                    wr_mem  : d_in.wr_mem[i],
                    rd_mem  : d_in.rd_mem[i],
                    tag     : d_in.tag[i],
                    t_old   : d_in.t_old[i],
                    dst     : d_in.dst[i],
                    halt    : d_in.halt[i],
                    illegal : d_in.illegal[i]
                };
            end
        end
    end

    `ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | >> ROB >>", $time);
            $display("r_out: en_cnt: %d", r_out.r_vld_cnt);
            for (int i = 0; i < `N; ++i) begin
                $display("r_out[%d]: tag: %d, t_old: %d, dst: %d, halt: %d, illegal: %d, is_brch: %d",
                    i,
                    r_out.tag[i],
                    r_out.t_old[i],
                    r_out.dst[i],
                    r_out.halt[i],
                    r_out.illegal[i],
                    r_out.is_brch[i]
                );
            end

            for (int i = 0; i < `ROB_SZ; ++i) begin
                $display("Rob[%2d]: cpl %b, t: %2d, t_old: %2d, dst: %2d, is_brch: %b, wr_mem: %b, rd_mem: %b, halt: %0b, illegal: %0b%s",
                    i,
                    state[i].cpl,
                    state[i].tag,
                    state[i].t_old,
                    state[i].dst,
                    state[i].is_brch,
                    state[i].wr_mem,
                    state[i].rd_mem,
                    state[i].halt,
                    state[i].illegal,
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
            $display("  %3d | << ROB <<", $time);

        end
    end
    `endif

endmodule
