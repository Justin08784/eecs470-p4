`include "sys_defs.svh"

module dispatch #(parameter 
    N=`N
) (
    input   clock,
    input   reset,
    input   flush,

    // branch manager
    input   bman2rename bman_in,
    output  rename2bman bman_out,
    // snapshot bus
    output  rename2snap_bus rnme_snap_out,
    output  comm2snap_bus   comm_snap_out,

    // DECODE
    input   decode2dispatch d_in,
    output  dispatch2decode d_out,

    // RS
    input   rs2dispatch rs_in,
    output  dispatch2rs rs_out,

    // ROB
    input   rob2dispatch rob_in,
    output  dispatch2rob rob_out,

    // Free list
    input   free_list2dispatch free_in,
    output  dispatch2free_list free_out,

    // CDB (completions)
    input   execute2complete_tag ctag_in,

    // Map table
    input   map_table2dispatch map_in,
    output  dispatch2map_table map_out
);

    logic [`PHYS_REG_SZ_R10K-1:0] cpl_lst;

    /* >> ==== 1. Alloc Stage ==== >> */
    logic [$clog2(N):0] alloc_en_cnt;
    logic [$clog2(N):0] alloc_rdy_scnt;
    logic [$clog2(N):0] alloc_vld_scnt;

    // Gate by availability
    logic [`N-1:0] has_dst;
    logic [`N:0][$clog2(`N):0] free_prefix_cnt;
    logic [$clog2(`N):0] free_lim_cnt;
    compactor #(
        .WIDTH(`N)
    ) comp_free (
        .req        (has_dst),
        .rdy        (free_in.free_rdy_scnt),
        .gnt_cnt    (free_lim_cnt),
        .prefix_cnt (free_prefix_cnt)
    );

    always_comb begin
        foreach (has_dst[n])
            has_dst[n] = d_in.d_dat[n].has_dst;

        // TODO: Is syntheizer smart enough to transform this MIN compute into a tree?
        alloc_en_cnt = d_in.d_vld_scnt;
        alloc_en_cnt = `MIN(rob_in.rob_rdy_scnt, alloc_en_cnt);
        alloc_en_cnt = `MIN(free_lim_cnt, alloc_en_cnt);
        alloc_en_cnt = `MIN(alloc_rdy_scnt, alloc_en_cnt);

        d_out.dispatch_en_cnt  = alloc_en_cnt;
        rob_out.alloc_en_cnt   = alloc_en_cnt;
        free_out.free_d_en_cnt = free_prefix_cnt[alloc_en_cnt];
    end

    ALLOC_RENAME_PKT [`N-1:0] tmp_decode2alloc;
    always_comb begin
        int rd_idx;

        tmp_decode2alloc = '0;
        for (int i = 0; i < `N; ++i) begin
            // logic [$bits(ALLOC_RENAME_PKT)-$bits(ID_RESULT)-1:0] diff;
            // diff = '0;
            // tmp_decode2alloc[i] = ALLOC_RENAME_PKT'({d_in.d_dat[i], diff});
            tmp_decode2alloc[i] = '{
                // from ID_RESULT
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
                t   : has_dst[i]
                    ? free_in.d_ts[free_prefix_cnt[i]]
                    : '0
            };

        end
    end

    ALLOC_RENAME_PKT [`N-1:0]  rename_in;
    logic [$clog2(N):0] rename_vld_scnt;
    logic [$clog2(N):0] rename_rdy_scnt;
    logic [$clog2(N):0] rename_en_cnt;
    logic [`N-1:0]      rename_en;
    fifo #(
        .INSTANCE_ID(39),
        .DEPTH(2*`N),
        .WIDTH($bits(ALLOC_RENAME_PKT)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_INTR_FWD(`FALSE)
    ) alloc_buf (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .wr_en_cnt  (alloc_en_cnt),
        .wr_data    (tmp_decode2alloc),
        .rd_en_cnt  (rename_en_cnt),
        .rd_data    (rename_in),

        .free_scnt  (alloc_rdy_scnt),
        .used_scnt  (alloc_vld_scnt)
    );

    /* >> ==== 2. Rename Stage ==== >> */

    logic [`N-1:0] rnme_is_brch;
    logic [`N:0][$clog2(`N):0] rnme_snap_prefix_cnt;
    logic [$clog2(`N):0] rnme_snap_lim_cnt;
    compactor #(
        .WIDTH(`N)
    ) comp_rnme_snap (
        .req        (rnme_is_brch),
        .rdy        (bman_in.snap_rdy_scnt),
        .gnt_cnt    (rnme_snap_lim_cnt),
        .prefix_cnt (rnme_snap_prefix_cnt)
    );

    always_comb begin
        foreach (rnme_is_brch[n])
            rnme_is_brch[n] = rename_in[n].fu_idx == FU_BRU;

        rename_en_cnt = alloc_vld_scnt;
        rename_en_cnt = `MIN(rename_rdy_scnt, rename_en_cnt);
        rename_en_cnt = `MIN(rnme_snap_lim_cnt, rename_en_cnt);
        // bman_out = '0; // FIXME: disable
        bman_out.snap_en_cnt = rnme_snap_prefix_cnt[rename_en_cnt];
    end

    // handle map table output 
    always_comb begin
        map_out = '0;
        map_out.en_cnt  = rename_en_cnt;

        for (int i = 0; i < rename_en_cnt; i++) begin
            //handling dest register
            map_out.ts[i]       = rename_in[i].t;
            map_out.dsts[i]     = rename_in[i].has_dst
                ? rename_in[i].inst.r.rd
                : `ZERO_REG;
            //handling src tags
            map_out.src1s[i]    = rename_in[i].inst.r.rs1;
            map_out.src2s[i]    = rename_in[i].inst.r.rs2;
        end
    end

    RENAME_COMMIT_PKT [`N-1:0] tmp_alloc2rename;
    always_comb begin
        logic [`N-1:0] rd_src1s;
        logic [`N-1:0] rd_src2s;

        tmp_alloc2rename = '0;
        for (int i = 0; i < `N; ++i) begin
            // logic [$bits(RENAME_COMMIT_PKT)-$bits(ALLOC_RENAME_PKT)-1:0] diff;
            // diff = '0;
            // tmp_alloc2rename[i] = RENAME_COMMIT_PKT'({rename_in[i], diff});
            tmp_alloc2rename[i] = '{
                // from ID_RESULT
`ifdef DEBUG
                id          : rename_in[i].id,
`endif
                PC          : rename_in[i].PC,
                inst        : rename_in[i].inst,
                fu_idx      : rename_in[i].fu_idx,

                alu_func    : rename_in[i].alu_func,
                opa_select  : rename_in[i].opa_select,
                opb_select  : rename_in[i].opb_select,

                has_dst     : rename_in[i].has_dst,
                cond_branch : rename_in[i].cond_branch,
                halt        : rename_in[i].halt,
                illegal     : rename_in[i].illegal,
                csr_op      : rename_in[i].csr_op,
                btq_idx     : rename_in[i].btq_idx,

                // alloc
                t           : rename_in[i].t,
                // rename
                b1hot       : '0,
                bmask       : '0,
                t_old       : '0,
                t1          : '0,
                t2          : '0,
                t1_rdy      : '0,
                t2_rdy      : '0
            };

            tmp_alloc2rename[i].t       = map_out.ts[i];
            tmp_alloc2rename[i].t_old   = map_in.ts_old[i];
            tmp_alloc2rename[i].t1      = map_in.t1s[i];
            tmp_alloc2rename[i].t2      = map_in.t2s[i];

            tmp_alloc2rename[i].b1hot = bman_in.b1hot_n[rnme_snap_prefix_cnt[i]];
            tmp_alloc2rename[i].bmask = bman_in.bmask_n[rnme_snap_prefix_cnt[i]];

            // actually need src tags?
            rd_src1s[i] = rename_in[i].opa_select == OPA_IS_RS1
                || rename_in[i].cond_branch;
            rd_src2s[i] = rename_in[i].opb_select == OPB_IS_RS2
                || rename_in[i].cond_branch
                || rename_in[i].fu_idx == FU_STR;
            tmp_alloc2rename[i].t1_rdy  = !rd_src1s[i];
            tmp_alloc2rename[i].t2_rdy  = !rd_src2s[i];
        end

        for (int i = 0; i < `N; ++i) begin
            rnme_snap_out.snap_en[i] = rnme_is_brch[i] && (i < rename_en_cnt);
            rnme_snap_out.b1hot_n[i] = bman_in.b1hot_n[rnme_snap_prefix_cnt[i]]; // only valid if snap_en
            rnme_snap_out.btq_tail[i]= rename_in[i].btq_idx;
        end
    end

    RENAME_COMMIT_PKT [`N-1:0]  commit_in;
    logic [$clog2(N):0] commit_en_cnt;
    logic [`N-1:0]      commit_en;
    fifo #(
        .INSTANCE_ID(40),
        .DEPTH(2*`N),
        .WIDTH($bits(RENAME_COMMIT_PKT)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_INTR_FWD(`FALSE)
    ) rename_buf (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .wr_en_cnt  (rename_en_cnt),
        .wr_data    (tmp_alloc2rename),
        .rd_en_cnt  (commit_en_cnt),
        .rd_data    (commit_in),

        .free_scnt  (rename_rdy_scnt),
        .used_scnt  (rename_vld_scnt)
    );

    /* >> ==== 3. Commit Stage ==== >> */

    logic [`N-1:0] comm_is_brch;
    logic [`N:0][$clog2(`N):0] comm_snap_prefix_cnt;
    compactor #(
        .WIDTH(`N)
    ) comp_comm_snap (
        .req        (comm_is_brch),
        .rdy        (),
        .gnt_cnt    (),
        .prefix_cnt (comm_snap_prefix_cnt)
    );

    // handle rs output 
    always_comb begin
        logic [`FU_IDX_NUM-1:0][`N-1:0] en_by_fu;
        logic [`N-1:0] commit_en;

        foreach (comm_is_brch[n])
            comm_is_brch[n] = commit_in[n].fu_idx == FU_BRU;

        foreach (en_by_fu[f, n]) begin
            en_by_fu[f][n] = (n < rename_vld_scnt)
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
            // logic [$bits(COMMIT_RS_PKT)-$bits(RENAME_COMMIT_PKT)-1:0] diff;
            // diff = '0;
            // rs_out.dat[i] = COMMIT_RS_PKT'({commit_in[i], diff});
            rs_out.dat[i] = '{
                // from ID_RESULT
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
                bmask       : commit_in[i].bmask,
                t_old       : commit_in[i].t_old,
                t1          : commit_in[i].t1,
                t2          : commit_in[i].t2,
                t1_rdy      : commit_in[i].t1_rdy,
                t2_rdy      : commit_in[i].t2_rdy,
                // commit
                rob_idx     : '0
            };

            rs_out.dat[i].rob_idx = rob_in.rob_idxs[i];
            for (int c = 0; c < `N; ++c) begin
                rs_out.dat[i].t1_rdy |= ctag_in.en[c] & (ctag_in.ts[c] == commit_in[i].t1);
                rs_out.dat[i].t2_rdy |= ctag_in.en[c] & (ctag_in.ts[c] == commit_in[i].t2);
            end
            rs_out.dat[i].t1_rdy |= cpl_lst[commit_in[i].t1];
            rs_out.dat[i].t2_rdy |= cpl_lst[commit_in[i].t2];

            comm_snap_out.snap_en[i]= comm_is_brch[i] && (i < commit_en_cnt);
            comm_snap_out.b1hot_n[i]= commit_in[i].b1hot; // only valid if snap_en
            comm_snap_out.rob_tail[i]=rob_in.rob_idxs[i];
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
        if (reset || flush) begin
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
        $display("BMAN: bmask: %b", bman_in.bmask_n[0]);
        $display("rspc: {%1d, %1d, %1d}", 
            rnme_snap_prefix_cnt[0],
            rnme_snap_prefix_cnt[1],
            rnme_snap_prefix_cnt[2]
        );
        $display("bman_out.snap_en_cnt: %1d", bman_out.snap_en_cnt);
        $display("rnme_snap_out.snap_en: %b", rnme_snap_out.snap_en);
        $display("rob_in.rob_rdy_scnt: %d",  rob_in.rob_rdy_scnt);
        $display("d_in.d_vld_scnt: %d",  d_in.d_vld_scnt);
        $display("free_in.free_rdy_scnt: %d [%d, %d]",  free_in.free_rdy_scnt, free_in.d_ts[0], free_in.d_ts[1]);
        $display("  %3d | << Dispatch <<", $time);
    endtask
`endif

endmodule


