`include "sys_defs.svh"

module dispatch #(parameter 
    N=`N
) (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,

    // branch manager
    input   bman2rename bman_in,
    output  rename2bman bman_out,
    // snapshot bus
    output  rename2snap_bus rnme_snap_out,
    output  comm2snap_bus   comm_snap_out,

    // decode
    input   decode2dispatch d_in,
    output  dispatch2decode d_out,

    // rs
    input   rs2dispatch rs_in,
    output  dispatch2rs rs_out,

    // rob
    input   rob2dispatch rob_in,
    output  dispatch2rob rob_out,

    // free list
    input   free_list2dispatch free_in,
    output  dispatch2free_list free_out,

    // cdb (completions)
    input   execute2complete_tag ctag_in,

    // map table
    input   map_table2dispatch map_in,
    output  dispatch2map_table map_out
);

    logic [`PHYS_REG_SZ_R10K-1:0] cpl_lst;

    /* >> ==== 1. Rename stage ==== >> */
    // Gate by availability
    logic [`N-1:0] has_dst;
    logic [`N:0][`CNT_SIZE(`N)-1:0] free_prefix_cnt;
    `CNT_TYPE(`N) free_lim_cnt;
    compactor #(
        .REQW(`N),
        .GNTW(`N)
    ) comp_free (
        .req        (has_dst),
        .lim_cnt    (free_in.free_rdy_scnt),
        .prefix_cnt (free_prefix_cnt),
        .gnt_cnt    (free_lim_cnt)
    );

    always_comb begin
        foreach (has_dst[n])
            has_dst[n] = d_in.d_dat[n].has_dst;
    end

    `CNT_TYPE(N) rename_vld_scnt;
    `CNT_TYPE(N) rename_rdy_scnt;
    `CNT_TYPE(N) rename_en_cnt;
    logic [`N-1:0]      rename_en;

    logic [`N-1:0] rnme_is_brch;
    logic [`N:0][`CNT_SIZE(`N)-1:0] rnme_snap_prefix_cnt;
    `CNT_TYPE(`N) rnme_snap_lim_cnt;
    compactor #(
        .REQW(`N),
        .GNTW(`N)
    ) comp_rnme_snap (
        .req        (rnme_is_brch),
        .lim_cnt    (bman_in.snap_rdy_scnt),
        .prefix_cnt (rnme_snap_prefix_cnt),
        .gnt_cnt    (rnme_snap_lim_cnt)
    );

    always_comb begin
        foreach (rnme_is_brch[n])
            rnme_is_brch[n] = d_in.d_dat[n].fu_idx == FU_BRU;

        rename_en_cnt = d_in.d_vld_scnt;
        rename_en_cnt = `MIN(free_lim_cnt, rename_en_cnt);
        rename_en_cnt = `MIN(rename_rdy_scnt, rename_en_cnt);
        rename_en_cnt = `MIN(rnme_snap_lim_cnt, rename_en_cnt);

        d_out.dispatch_en_cnt  = rename_en_cnt;
        free_out.free_d_en_cnt = free_prefix_cnt[rename_en_cnt];
        bman_out.snap_en_cnt = rnme_snap_prefix_cnt[rename_en_cnt];
    end

    // handle map table output 
    always_comb begin
        map_out = '0;
        map_out.en_cnt  = rename_en_cnt;

        for (int i = 0; i < `N; i++) begin
            //handling dest register
            map_out.ts[i]       = has_dst[i] ? free_in.d_ts[free_prefix_cnt[i]] : '0;
            map_out.dsts[i]     = d_in.d_dat[i].has_dst
                ? d_in.d_dat[i].inst.r.rd
                : `ZERO_REG;
            //handling src tags
            map_out.src1s[i]    = d_in.d_dat[i].inst.r.rs1;
            map_out.src2s[i]    = d_in.d_dat[i].inst.r.rs2;
        end
    end

    RENAME_COMMIT_PKT [`N-1:0] rename2commit;
    BMASK             [`N-1:0] rename2commit_bmask;
    always_comb begin
        rename2commit = '0;
        for (int i = 0; i < `N; ++i) begin
            rename2commit[i] = '{
`ifdef DEBUG
                id          : d_in.d_dat[i].id,
`endif
                PC          : d_in.d_dat[i].PC,
                inst        : d_in.d_dat[i].inst,
                fu_idx      : d_in.d_dat[i].fu_idx,

                alu_func    : d_in.d_dat[i].alu_func,
                opa_select  : d_in.d_dat[i].opa_select,
                opb_select  : d_in.d_dat[i].opb_select,

                has_dst     : d_in.d_dat[i].has_dst,
                cond_branch : d_in.d_dat[i].cond_branch,
                halt        : d_in.d_dat[i].halt,
                illegal     : d_in.d_dat[i].illegal,
                csr_op      : d_in.d_dat[i].csr_op,
                btq_idx     : d_in.d_dat[i].btq_idx,

                // alloc
                t           : '0,
                // rename
                b1hot       : '0,
                t_old       : '0,
                t1          : '0,
                t2          : '0
            };

            rename2commit[i].t       = map_out.ts[i];
            rename2commit[i].t_old   = map_in.ts_old[i];
            rename2commit[i].t1      = map_in.t1s[i];
            rename2commit[i].t2      = map_in.t2s[i];

            rename2commit[i].b1hot = bman_in.b1hot_n[rnme_snap_prefix_cnt[i]];
            rename2commit_bmask[i] = bman_in.bmask_n[rnme_snap_prefix_cnt[i]];
        end

        for (int i = 0; i < `N; ++i) begin
            rnme_snap_out.snap_en[i] = rnme_is_brch[i] && (i < rename_en_cnt);
            rnme_snap_out.b1hot_n[i] = bman_in.b1hot_n[rnme_snap_prefix_cnt[i]]; // only valid if snap_en
            rnme_snap_out.fl_head[i] = free_in.fl_heads_n[free_prefix_cnt[i] + has_dst[i]];
                // Q: Why "+ has_dst[i]"? A: Remember, we want to snapshot the free_list
                // head immediately AFTER the branch. The next free_list head is incremented IFF we consume a preg.
            rnme_snap_out.btq_tail[i]= d_in.d_dat[i].btq_idx + 1 >= `BTQ_SZ ?
                0 :
                d_in.d_dat[i].btq_idx + 1;
            rnme_snap_out.ras_snap[i]= d_in.d_dat[i].ras_snap;
`ifdef DEBUG
            rnme_snap_out.btq_idx[i] = d_in.d_dat[i].btq_idx;
`endif
        end
    end

    /*
    NOTE:
    To save area, we can size this buffer to 2*`N and use
    combinational backpressure:
    rename_en_cnt = `MIN(rename_rdy_scnt + commit_en_cnt, rename_en_cnt);
    */
    RENAME_COMMIT_PKT [`N-1:0]  commit_in;
    BMASK [`N-1:0] commit_in_bmask;
    `CNT_TYPE(N) commit_en_cnt;
    logic [`N-1:0]      commit_en;
    fifo #(
        .INSTANCE_ID(40),
        .DEPTH(2*`N),
        .WIDTH($bits(RENAME_COMMIT_PKT)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE)
    ) rename_buf (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .clmsk      (clmsk),

        .wr_en_cnt  (rename_en_cnt),
        .wr_data    (rename2commit),
        .wr_bmask   (rename2commit_bmask),
        .rd_en_cnt  (commit_en_cnt),
        .rd_data    (commit_in),
        .rd_bmask   (commit_in_bmask),

        .free_scnt  (rename_rdy_scnt),
        .used_scnt  (rename_vld_scnt)
    );

    /* >> ==== 2. Commit Stage ==== >> */

    logic [`N-1:0] comm_is_brch;
    // handle rs output 
    always_comb begin
        logic [`FU_IDX_NUM-1:0][`N-1:0] en_by_fu;
        logic [`N-1:0] commit_en;
        logic [`N-1:0] rd_src1s;
        logic [`N-1:0] rd_src2s;

        foreach (comm_is_brch[n])
            comm_is_brch[n] = commit_in[n].fu_idx == FU_BRU;

        foreach (en_by_fu[f, n]) begin
            en_by_fu[f][n] = (n < rename_vld_scnt)
                && (n < rob_in.rob_rdy_scnt)
                && commit_in[n].fu_idx == f
                && rs_in.rdy_sbus[f][n];
        end

        commit_en   = '0;
        foreach (en_by_fu[f, n])
            commit_en[n] |= en_by_fu[f][n];
        // enforce in-order dispatch
        for (int n = 1; n < `N; ++n)
            commit_en[n] &= commit_en[n - 1];

        commit_en_cnt       = $countones(commit_en);
        foreach (rs_out.en[f]) begin
            rs_out.en[f]    = commit_en & en_by_fu[f];
        end

        rs_out.dat    = '0;
        for (int i = 0; i < `N; i++) begin
            rs_out.dat[i] = '{
`ifdef DEBUG
                id          : commit_in[i].id,
`endif
                PC          : commit_in[i].PC,
                inst        : commit_in[i].inst,
                fu_idx      : commit_in[i].fu_idx,

                alu_func    : commit_in[i].alu_func,
                opa_select  : commit_in[i].opa_select,
                opb_select  : commit_in[i].opb_select,

                has_dst     : commit_in[i].has_dst,
                cond_branch : commit_in[i].cond_branch,
                halt        : commit_in[i].halt,
                illegal     : commit_in[i].illegal,
                csr_op      : commit_in[i].csr_op,
                btq_idx     : commit_in[i].btq_idx,

                // alloc
                t           : commit_in[i].t,
                // rename
                b1hot       : commit_in[i].b1hot,
                bmask       : commit_in_bmask[i],
                t_old       : commit_in[i].t_old,
                t1          : commit_in[i].t1,
                t2          : commit_in[i].t2,
                t1_rdy      : '0,
                t2_rdy      : '0,
                // commit
                rob_idx     : '0
            };

            rs_out.dat[i].rob_idx = rob_in.rob_idxs_n[i];

            // tag readiness check
            rd_src1s[i] = commit_in[i].opa_select == OPA_IS_RS1
                || commit_in[i].cond_branch;
            rd_src2s[i] = commit_in[i].opb_select == OPB_IS_RS2
                || commit_in[i].cond_branch
                || commit_in[i].fu_idx == FU_STR;
            rs_out.dat[i].t1_rdy = !rd_src1s[i];
            rs_out.dat[i].t2_rdy = !rd_src2s[i];
            for (int c = 0; c < `N; ++c) begin
                rs_out.dat[i].t1_rdy |= ctag_in.en[c] & (ctag_in.ts[c] == commit_in[i].t1);
                rs_out.dat[i].t2_rdy |= ctag_in.en[c] & (ctag_in.ts[c] == commit_in[i].t2);
            end
            rs_out.dat[i].t1_rdy |= cpl_lst[commit_in[i].t1];
            rs_out.dat[i].t2_rdy |= cpl_lst[commit_in[i].t2];

            comm_snap_out.snap_en[i]= comm_is_brch[i] && (i < commit_en_cnt);
            comm_snap_out.b1hot_n[i]= commit_in[i].b1hot; // only valid if snap_en
            comm_snap_out.rob_tail[i]=rob_in.rob_idxs_n[i + 1];
                /* Q: Why +1?
                A: Checkpoint the tail AFTER us. The mispredicted branch still retires.
                */
        end
    end

    // handle rob output 
    always_comb begin
        rob_out.d_en_cnt = commit_en_cnt;

        for (int i = 0; i < `N; i++) begin
            //handling src tags
            rob_out.fu_idx[i]   = commit_in[i].fu_idx;
            rob_out.tag[i]      = commit_in[i].t;
            rob_out.t_old[i]    = commit_in[i].t_old;
            //handling dest register
            rob_out.dst[i]      = commit_in[i].has_dst
                ? commit_in[i].inst.r.rd
                : `ZERO_REG;

            rob_out.halt[i]     = commit_in[i].halt;
            rob_out.illegal[i]  = commit_in[i].illegal;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            cpl_lst <= '1;
        end else begin
            for (int i = 0; i < map_out.en_cnt; ++i) begin
                if (map_out.dsts[i] != `ZERO_REG)
                    cpl_lst[map_out.ts[i]] <= 0;
            end
            for (int c = 0; c < `N; ++c) begin
                if (ctag_in.en[c])
                    cpl_lst[ctag_in.ts[c]] <= 1;
            end
        end
    end

`ifdef DEBUG
    task print_dispatch;
        $display("  %3d | >> Dispatch >>", $time);
        // $display("r_in.btq_rdy_scnt: %d",   btq_in.btq_rdy_scnt);
        // $display("btq_in.btq_rdy_scnt: %d",   btq_in.btq_rdy_scnt);
        $display("BMAN: bmask: %b (alloc: %2d)", bman_in.bmask_n[0], $countones(bman_in.bmask_n[0]));
        $display("rspc: {%1d, %1d, %1d}", 
            rnme_snap_prefix_cnt[0],
            rnme_snap_prefix_cnt[1],
            rnme_snap_prefix_cnt[2]
        );
        $display("bman_in.snap_rdy_scnt: %1d", bman_in.snap_rdy_scnt);
        $display("bman_out.snap_en_cnt: %1d", bman_out.snap_en_cnt);
        $display("rnme_snap_out.snap_en: %b", rnme_snap_out.snap_en);
        $display("rob_in.rob_rdy_scnt: %d",  rob_in.rob_rdy_scnt);
        $display("d_in.d_vld_scnt: %d",  d_in.d_vld_scnt);
        $display("free_in.free_rdy_scnt: %d [%d, %d]",  free_in.free_rdy_scnt, free_in.d_ts[0], free_in.d_ts[1]);

        $display("");
        for (int i = 0; i < `N+1; ++i) begin
            $display("prefix_cnt[%2d]: rnme_snap: %2d free: %2d",
            i, rnme_snap_prefix_cnt[i], free_prefix_cnt[i]);
        end

        for (int i = 0; i < `N+1; ++i) begin
            $display("free_in.fl_heads_n[%2d]: %2d", i, free_in.fl_heads_n[i]);
        end

        for (int i = 0; i < `N; ++i) begin
            $display("rnme_snap_out[%2d]: en: %b, b1hot_n: %b, fl_head: %2d, btq_tail: %2d",
                i,
                rnme_snap_out.snap_en[i],
                rnme_snap_out.b1hot_n[i],
                rnme_snap_out.fl_head[i],
                rnme_snap_out.btq_tail[i]
            );
        end
        $display("  %3d | << Dispatch <<", $time);
    endtask
`endif

endmodule


