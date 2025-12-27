`include "sys_defs.svh"

typedef struct packed {
    logic           cpl;
    PHYS_REG_IDX    tag;
    PHYS_REG_IDX    t_old;
    REG_IDX         dst;

    FU_IDX          fu_idx;
    logic           halt;
    logic           illegal;
} ROB_ENTRY;

module rob #(
    parameter ROB_SZ = ROB_SZ,  // num elements
    parameter N=N
) (
    input clock, reset, flush,
    input  BMASK clmsk,

    // retire (read)
    output rob2retire r_out,
    input  RETIRE_PKT r_in,

    // complete (write)
    input  execute2complete_bru cbru_in,
    input  execute2complete_str cstr_in,
    input  execute2complete_dat cdat_in,

    // dispatch (write)
    input  comm2snap_bus snap_in, // alloc snapshot
    output rob2dispatch d_out,
    input  dispatch2rob d_in
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)
    `CNT_TYPE(NUM_DPORTS) free_scnt;
    `CNT_TYPE(NUM_RPORTS) used_scnt;

    ROB_ENTRY [ROB_SZ-1:0]  state;
    `IDX_TYPE(ROB_SZ) head, tail, snap;
    `CNT_TYPE(ROB_SZ) used, free;

    logic [NUM_RPORTS:0][`IDX_SIZE(ROB_SZ)-1:0] rtre_idxs_n;
    logic [NUM_DPORTS:0][`IDX_SIZE(ROB_SZ)-1:0] comm_idxs_n;

    ring_ctr #(
        .DEPTH(ROB_SZ),
        .RPORTS(NUM_RPORTS),
        .WPORTS(NUM_DPORTS),
        .FLUSH_MODE(FIFO_FLUSH_SNAP_TAIL)
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,
        .flush_snap (snap),

        .rd_en_cnt  (r_in.en_cnt),
        .wr_en_cnt  (d_in.wen_cnt),

        .head,
        .tail,
        .rd_idxs_n    (rtre_idxs_n),
        .wr_idxs_n    (comm_idxs_n),

        .used,
        .free,
        .used_scnt,
        .free_scnt
    );

    general_snaps #(
        .WIDTH(`IDX_SIZE(ROB_SZ))
    ) rob_tails (
        .clock,

        .rmsk   (clmsk),
        .rdat   (snap),

        .wen    (snap_in.snap_en),
        .wmsk   (snap_in.b1hot_n),
        .wdat   (snap_in.rob_tail)
    );

    always_comb begin
        // handle retire (outs)
        r_out = '0;
        r_out.vld_scnt = used_scnt;
        for (int i = 0; i < used_scnt; ++i) begin
            ROB_ENTRY cur;
            cur = state[rtre_idxs_n[i]];
            /* preview mode–– just display all valid entries in read window even
            if not all will get retired this cycle */
`ifndef SYNTH
            r_out.tag   [i] = cur.tag;
            r_out.dst   [i] = cur.dst;
`endif
            r_out.cpl   [i] = cur.cpl;
            r_out.t_old [i] = cur.t_old;
            r_out.fu_idx[i] = cur.fu_idx;
            r_out.halt  [i] = cur.halt;
            r_out.illegal[i]= cur.illegal;
        end

        // handle dispatch (outs)
        d_out = '{
            rdy_scnt    : free_scnt,
            rob_idxs_n  : comm_idxs_n
        };
    end

    always_ff @(posedge clock) begin
`ifndef SYNTH
        if (d_in.wen_cnt > free + r_out.vld_scnt)
            $error("ROB overflow!");
        if (r_out.vld_scnt > used + d_in.wen_cnt)
            $error("ROB underflow!");
`endif
        // handle complete (ins)
        for (int i = 0; i < NUM_FU_BRU; ++i) begin
            int cur_idx;
            cur_idx = cbru_in.rob_idx[i];

            if (cbru_in.en[i])
                state[cur_idx].cpl <= 1'b1;
        end

        for (int i = 0; i < NUM_FU_STR; ++i) begin
            int cur_idx;
            cur_idx = cstr_in.dat[i].rob_idx;

            if (cstr_in.en[i])
                state[cur_idx].cpl <= 1'b1;
        end

        for (int unsigned i = 0, int cur_idx = 0; i < NUM_CPORTS; ++i) begin
            cur_idx = cdat_in.rob_idxs[i];

            if (cdat_in.en[i])
                state[cur_idx].cpl <= 1;
        end

        // handle dispatch (ins)
        for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
            if (i >= d_in.wen_cnt)
                continue;
            cur_idx = comm_idxs_n[i];
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
    

`ifdef DEBUG
    task print_rob;
        logic [ROB_SZ-1:0] rob_vld;
        logic t_dup, told_dup;
        localparam half_sz = ROB_SZ / 2;

        $display("  | >> ROB >>");
        for (int i = 0; i < N; ++i) begin
            $display("snap_in[%1d]: en: %b, b1hot_n: %b, rob_tail: %2d",
                i,
                snap_in.snap_en[i],
                snap_in.b1hot_n[i],
                snap_in.rob_tail[i]
            );
        end
        // $display("fl: en_cnt: %d, [%2d, %2d] fldup: %b",
        //     verisimpleV.free_list0.free_cnt,
        //     verisimpleV.free_list0.told_packed[0],
        //     verisimpleV.free_list0.told_packed[1],
        //     verisimpleV.free_list0.told_packed[0]
        //     ==verisimpleV.free_list0.told_packed[1]
        //     &&verisimpleV.free_list0.told_packed[0]!=0
        // );

        $display("r_out: vld_scnt: %d", r_out.vld_scnt);
        $display("head: %2d, tail: %2d, used: %2d", head, tail, used);
        for (int i = 0; i < N; ++i) begin
            string name;
            get_fu_name(r_out.fu_idx[i], name);
            $display("r_out[%d]: tag: %d, t_old: %d, dst: %d, fu_idx: %s, halt: %d, illegal: %d",
                i,
                r_out.tag[i],
                r_out.t_old[i],
                r_out.dst[i],
                name,
                r_out.halt[i],
                r_out.illegal[i]
            );
        end

        $display("completions: bru: {en: %b, idx: %2d}, cdat[0]: {en: %b, idx: %2d}, cdat[1]: {en: %b, idx: %2d}",
            cbru_in.en[0],
            cbru_in.rob_idx[0],
            cdat_in.en[0],
            cdat_in.rob_idxs[0],
            cdat_in.en[1],
            cdat_in.rob_idxs[1]
        );

        rob_vld = '0;
        for (int cnt = 0; cnt < used; ++cnt)
            rob_vld[(head + cnt) % ROB_SZ] = 1;

        for (int i = 0; i < half_sz; ++i) begin
            string ls, rs, name;

            t_dup = 0;
            told_dup = 0;
            for (int j = 0; j < ROB_SZ; ++j) begin
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

            get_fu_name(state[i+half_sz].fu_idx, name);
            if (rob_vld[i+half_sz])
                rs = $sformatf("Rob[%2d]: {cpl:%b, hlt:%b}, %s, dst:%2d (%2d->%2d),",
                    i+half_sz,
                    state[i+half_sz].cpl,
                    state[i+half_sz].halt,
                    // state[i+half_sz].illegal,
                    name,
                    state[i+half_sz].dst,
                    state[i+half_sz].t_old,
                    state[i+half_sz].tag
                    // state[i].is_brch,
                    // state[i].wr_mem,
                    // state[i].rd_mem,
                    // t_dup,
                    // told_dup
                );
            else
                rs = $sformatf("Rob[%2d]:", i+half_sz);

           $display("%-50s | %-50s", ls, rs); 
        end

        $display("  | << ROB <<");
    endtask

`endif

endmodule
