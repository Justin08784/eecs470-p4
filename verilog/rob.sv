`include "sys_defs.svh"

module rob #(
    parameter ROB_SZ = `ROB_SZ,  // num elements
    parameter N=`N
) (
    input clock, reset, flush,
    input  BMASK clmsk,

    // retire (read)
    output rob2retire r_out,
    input  retire_final r_in,

    // complete (write)
    input  execute2complete_dat cdat_in,

    // dispatch (write)
    input  bman2snap_bus snap_in, // alloc snapshot
    output rob2dispatch d_out,
    input  dispatch2rob d_in
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(ROB_SZ)-1:0]  head;
    logic [$clog2(ROB_SZ)-1:0]  tail;
    logic [$clog2(ROB_SZ)-1:0]  snap;

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

    ring_ctr #(
        .DEPTH(ROB_SZ),
        .WIDTH($bits(ROB_ENTRY)),
        .RPORTS(NUM_RPORTS),
        .WPORTS(NUM_DPORTS),
        .FLUSH_MODE(FIFO_FLUSH_RESET) // FIXME
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,
        .flush_tail (snap),

        .rd_en_cnt  (r_in.r_en_cnt),
        .wr_en_cnt  (d_in.d_en_cnt),

        .head,
        .tail,
        .rd_idxs    (rtre_idxs),
        .wr_idxs    (comm_idxs),

        .used,
        .free,
        .used_scnt,
        .free_scnt() // DO NOT wire. Will compute this ourselves.
    );

    general_snaps #(
        .WIDTH($clog2(`ROB_SZ))
    ) rob_tails (
        .clock,

        .rmsk   (clmsk),
        .rdat   (snap),

        .wen_cnt(snap_in.snap_en_cnt),
        .wmsk   (snap_in.b1hot_n),
        .wdat   (snap_in.rob_tail)
    );

    assign free_scnt    = `MIN(free - rsvd, NUM_DPORTS);

    always_comb begin
        // handle retire (outs)
        r_out = '0;
        r_out.r_vld_cnt = used_scnt;
        for (int unsigned i = 0; i < used_scnt; ++i) begin
            /* preview mode–– just display all valid entries in read window even
            if not all will get retired this cycle */
            r_out.entries[i] = state[rtre_idxs[i]];
        end

        // handle dispatch (outs)
        d_out = '{
            rob_rdy_scnt : free_scnt,
            rob_idxs     : comm_idxs
        };
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            rsvd    <= 0;
            state   <= '0;
        end else begin
`ifndef SYNTH
            if (d_in.d_en_cnt > free + r_out.r_vld_cnt)
                $error("ROB overflow!");
            if (r_out.r_vld_cnt > used + d_in.d_en_cnt)
                $error("ROB underflow!");
`endif
            rsvd    <= rsvd - d_in.d_en_cnt + d_in.alloc_en_cnt;

            // handle complete (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_CPORTS; ++i) begin
                cur_idx = cdat_in.rob_idxs[i];

                if (cdat_in.en[i])
                    state[cur_idx].cpl <= 1;
            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= d_in.d_en_cnt)
                    continue;
                cur_idx = comm_idxs[i];
                state[cur_idx] <= '{
                    cpl     : 0,
                    fu_idx  : d_in.fu_idx[i],
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
    task print_rob;
        logic [`ROB_SZ-1:0] rob_vld;
        logic t_dup, told_dup;

        $display("  | >> ROB >>");
        $display("fl: en_cnt: %d, [%2d, %2d] fldup: %b",
            verisimpleV.free_list0.free_cnt,
            verisimpleV.free_list0.told_packed[0],
            verisimpleV.free_list0.told_packed[1],
            verisimpleV.free_list0.told_packed[0]
            ==verisimpleV.free_list0.told_packed[1]
            &&verisimpleV.free_list0.told_packed[0]!=0
        );
        $display("r_out: vld_cnt: %d", r_out.r_vld_cnt);
        for (int i = 0; i < `N; ++i) begin
            string name;
            get_fu_name(r_out.entries[i].fu_idx, name);
            $display("r_out[%d]: tag: %d, t_old: %d, dst: %d, fu_idx: %s, halt: %d, illegal: %d",
                i,
                r_out.entries[i].tag,
                r_out.entries[i].t_old,
                r_out.entries[i].dst,
                name,
                r_out.entries[i].halt,
                r_out.entries[i].illegal
            );
        end

        rob_vld = '0;
        for (int cnt = 0; cnt < used; ++cnt)
            rob_vld[(head + cnt) % `ROB_SZ] = 1;

        for (int i = 0; i < `ROB_SZ / 2; ++i) begin
            string ls, rs, name;

            t_dup = 0;
            told_dup = 0;
            for (int j = 0; j < `ROB_SZ; ++j) begin
                if (!rob_vld[j] || i == j)
                    continue;
                if (state[i].tag == state[j].tag && state[i].tag != '0)
                    t_dup |= 1;
                if (state[i].t_old == state[j].t_old && state[i].t_old != '0)
                    told_dup |= 1;
            end

            get_fu_name(state[i].fu_idx, name);
            if (rob_vld[i])
                ls = $sformatf("Rob[%2d]: {cpl:%b, hlt:%b}, %s, dst:%2d (%2d->%2d)",
                    i,
                    state[i].cpl,
                    state[i].halt,
                    // state[i].illegal,
                    name,
                    state[i].dst,
                    state[i].t_old,
                    state[i].tag
                    // state[i].is_brch,
                    // state[i].wr_mem,
                    // state[i].rd_mem,
                    // t_dup,
                    // told_dup
                );
            else
                ls = $sformatf("Rob[%2d]:", i);

            get_fu_name(state[i+32].fu_idx, name);
            if (rob_vld[i+32])
                rs = $sformatf("Rob[%2d]: {cpl:%b, hlt:%b}, %s, dst:%2d (%2d->%2d),",
                    i+32,
                    state[i+32].cpl,
                    state[i+32].halt,
                    // state[i+32].illegal,
                    name,
                    state[i+32].dst,
                    state[i+32].t_old,
                    state[i+32].tag
                    // state[i].is_brch,
                    // state[i].wr_mem,
                    // state[i].rd_mem,
                    // t_dup,
                    // told_dup
                );
            else
                rs = $sformatf("Rob[%2d]:", i+32);

           $display("%-50s | %-50s", ls, rs); 
        end

        $display("  | << ROB <<");
    endtask
`endif

endmodule
