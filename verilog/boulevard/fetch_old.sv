
// decoupled fetch
module dcf_v1 (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,
    // input   WADDR flush_PC,
        /*
        WRONG >> 
            FIXME: this should/would be an FB base...?
        <<
        If branch was mispred NT-resolved T, then flush_PC indeed will be an fb_base.
        However, if branch was mispred T-resolved NT, then flush_PC may NOT be an
        fb_base–– instead flush_PC is more likely to be a nonzero offset INO the FB.
        */
    input   WADDR flush_fb_base,
    input   logic [3:0] flush_fb_off,

    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   btq2fetch   btq_in,
    output  fetch2btq   btq_out,

    // execute
    input   execute2complete_bru cbru_in,

    input   rename2snap_bus snap_in, // unused

    output  fetch2mem   mem_out,
    input   mem2fetch   mem_in
);
    struct packed {
        logic [3:0] off;
        WADDR fb_base;
    } cur, cur_n;

    // bpu <-> ftq plumbing
    struct packed {
        logic       en;
        FTQ_ENTRY   dat;
    } bpu2ftq;
    struct packed {
        logic       rdy;
    } ftq2bpu;

    // ftq <-> fetch (us) plumbing
    struct packed {
        FTQ_ENTRY [1:0] rdat;
        `CNT_TYPE(2)    vld_scnt, ren_cnt;
    } ftq_io;

    bpu bpu0 (
        .clock,
        .reset,

        .flush,
        .flush_fb_base,
        .flush_fb_off,
        .clmsk,
        .cbru_in,

        .i_uen      (btq_in.bp_upd.en),
        .i_udat     (btq_in.bp_upd.dat),

        .i_ftq_rdy  (ftq2bpu.rdy),
        .o_ftq_en   (bpu2ftq.en),
        .o_ftq_dat  (bpu2ftq.dat)
    );

    ftq ftq0 (
        .clock,
        .reset,
        .flush,

        .rdy    (ftq2bpu.rdy),
        .wen    (bpu2ftq.en),
        .wdat   (bpu2ftq.dat),

        .vld_scnt   (ftq_io.vld_scnt),
        .rdat       (ftq_io.rdat),
        .ren_cnt    (ftq_io.ren_cnt)
    );

    // Form indices: fb offsets, PCs, block DWs
    logic   [1:0][4:0][3:0] off_n;
    DWADDR  [1:0][1:0] blk;
    logic   [1:0][1:0] blk_has_end;
    logic   [1:0][3:0] word_is_end;
    generate
    assign blk[0][0] = cur.fb_base[13:1]; // FIXME This is worng
    assign blk[0][1] = blk[0][0] + `UCAST_FIT(1); // FIXME and this too
    assign blk[1][0] = ftq_io.rdat[0].base_n;
    assign blk[1][1] = blk[1][0] + `UCAST_FIT(1);

    assign off_n[0][0] = cur.off;
    assign off_n[1][0] = 0;
    for (genvar i = 1; i <= 4; ++i) begin
        assign off_n[0][i] = cur.off + `UCAST_FIT(i);
        assign off_n[1][i] = i;
    end

    for (genvar e = 0; e < 2; ++e) begin
        for (genvar w = 0; w < 4; ++w) begin
            assign word_is_end[e][w] = off_n[e][w] == ftq_io.rdat[e].off;
        end
        for (genvar b = 0; b < 2; ++b) begin
            assign blk_has_end[e][b] =
                word_is_end[e][2*b] || word_is_end[e][2*b+1];
        end
    end
    endgenerate


    // logic [N:0][3:0]   off_n;
    WADDR [N:0]        pc_n;
    generate
    // assign off_n[0] = cur.off;
    // for (genvar i = 1; i < N+1; ++i) begin
    //     assign off_n[i] = cur.off + `UCAST_FIT(i);
    // end

    for (genvar i = 0; i < N+1; ++i) begin
        assign pc_n[i] = cur.fb_base + off_n[0][i];
    end

    assign mem_out.PCdws[0] = pc_n[0][13:1];
    for (genvar i = 1; i < N; ++i) begin // FIXME: These are mem blocks btw. Only works for N = 2;
        assign mem_out.PCdws[i] = pc_n[0][13:1] + `UCAST_FIT(i); // w -> dw
    end
    endgenerate

    // Align
    BRANCH_MD [2*N-1:0] md_raw;
    INST      [2*N-1:0] inst_raw;
    BRANCH_MD [N-1:0] md;
    INST      [N-1:0] inst;
    generate
    for (genvar i = 0; i < N; ++i) begin
        for (genvar woff = 0; woff < 2; ++woff) begin
            assign md_raw   [2*i + woff] = mem_in.insn_md[i][woff];
            assign inst_raw [2*i + woff] = mem_in.data[i].word_level[woff];
        end
    end

    logic base_woff;
    assign base_woff = pc_n[0];
    for (genvar i = 0; i < N; ++i) begin
        assign md[i]    = base_woff ? md_raw    [i+1] : md_raw  [i];
        assign inst[i]  = base_woff ? inst_raw  [i+1] : inst_raw[i];
    end
    endgenerate

    logic [N-1:0] brch, cond, call, ret, jalr;
    generate
    for (genvar i = 0; i < N; ++i) begin
        assign brch[i] = md[i].brch;
        assign cond[i] = md[i].cond;
        assign call[i] = md[i].call;
        assign ret [i] = md[i].ret;
        assign jalr[i] = md[i].jalr;
    end
    endgenerate

    // Process FTQ entry
    FTQ_ENTRY r;
    assign r = ftq_io.rdat;

        // Detect FB end
    logic [N-1:0] is_fb_end;
    logic fb_end_any;
    `IDX_TYPE(N) fb_end_idx;
    generate
    for (genvar i = 0; i < N; ++i)
        assign is_fb_end[i] = off_n[0][i] == r.off;
    endgenerate

    ffs #(
        .VECW(N)
    ) ff_end (
        .i_vec(is_fb_end),
        .o_vld(fb_end_any),
        .o_idx(fb_end_idx)
    );

        // Fetch-FSM: consume FTQ entry
    `CNT_TYPE(N) fsm_lim_cnt, f_cnt;
    always_comb begin
        fsm_lim_cnt =
            (ftq_io.vld_scnt == 0) ? 0 :
            fb_end_any  ? fb_end_idx + `UCAST_FIT(1) :
            N;

        cur_n = cur;
        ftq_io.ren_cnt = 0;
        if ((ftq_io.vld_scnt != 0) && fb_end_any && (fsm_lim_cnt == f_cnt)) begin
            // finished consuming FTQ entry (entry is valid and reached FB end)
            cur_n = '{
                fb_base : r.base_n, // advance FB base
                off     : 0         // reset in-fb offset
            };

            // signal consume to FTQ
            ftq_io.ren_cnt = 1;

        end else
            cur_n.off = off_n[0][f_cnt];

    end

    // Handle count
    `CNT_TYPE(N)   free_scnt, used_scnt;
    IF_ID_PKT [N-1:0]   f_dat;
        // BTQ limit
    `CNT_TYPE(N) brch_lim_cnt;
    logic [N:0][`CNT_SIZE(N)-1:0] brch_prefix_cnt;
    compactor #(
        .REQW(N),
        .GNTW(N)
    ) comp_brch (
        .req        (brch),
        .lim_cnt    (btq_in.rdy_scnt),
        .prefix_cnt (brch_prefix_cnt),
        .gnt_cnt    (brch_lim_cnt)
    );

    always_comb begin
        d_out.wen_cnt = `MIN(used_scnt, d_in.rdy_scnt);
        f_cnt = `MIN(fsm_lim_cnt, `MIN(brch_lim_cnt, free_scnt));
    end

    always_comb begin
        for (int unsigned i = 0; i < N; ++i) begin
            f_dat[i] = '{
                inst    : inst[i],
                PC      : pc_n[i],
                ras_snap: '0, // FIXME
                btq_idx : '0 // filled below
            };
        end

        btq_out = '0;
        btq_out.wen_cnt = brch_prefix_cnt[f_cnt];

        for (int i = 0; i < N; ++i) begin
            int     win_idx; // index into btq write window
            logic   eq_end;
            win_idx = brch_prefix_cnt[i];
            eq_end  = off_n[0][i] == r.off;

            f_dat[i].btq_idx = btq_in.btq_idxs_n[win_idx];

            btq_out.is_tail     [win_idx] = (r.pred_idx == 1) && eq_end;
                /* FIXME (unsure): Probably not necessary to check for "off_geq_tail",
                i.e. (r.pred_idx == 1) && (off_n[i] >= r.off), because branches after (>)
                the tail slot would not even be in the same fetch block? */
            btq_out.PC          [win_idx] = pc_n[i];
            btq_out.off         [win_idx] = off_n[0][i];
            btq_out.pred        [win_idx] = !r.ft && eq_end;
            btq_out.pred_tgt    [win_idx] = r.base_n;
            btq_out.always_take [win_idx] = !r.ft && eq_end ? r.always_take : 0;
            btq_out.md          [win_idx] = md[i];
                // TODO: fix RAS if pred ret but not ret (likewise for call)

            btq_out.hit         [win_idx] = r.hit;
            btq_out.hit_slot    [win_idx] =
                    (r.slot[0].vld && (r.slot[0].off == off_n[0][i]))
                ||  (r.slot[1].vld && (r.slot[1].off == off_n[0][i]));
            btq_out.hash        [win_idx] = '0; // FIXME
            btq_out.ghr_base    [win_idx] = '0; // FIXME
        end
    end

    fifo #(
        .DEPTH(2*N),
        .WIDTH($bits(IF_ID_PKT)),
        .NUM_RPORTS(N),
        .NUM_WPORTS(N),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(98)
    ) pc_buf (
        .clock,
        .reset,
        .flush,

        // >> unused inputs
        .flush_snap ('0),
        .clmsk      ('0),
        .wr_bmask   ('0),
        // << unused inputs

        .wr_en_cnt  (f_cnt),
        .wr_data    (f_dat),
        .rd_en_cnt  (d_out.wen_cnt),
        .rd_data    (d_out.dat),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    always_ff @(posedge clock) begin
        if (reset)
            cur <= '0;

        else if (flush)
            cur <= '{
                fb_base : flush_fb_base,
                off     : flush_fb_off
            };

        else
            cur <= cur_n;

    end

`ifdef DEBUG
    task print_fetch;
        logic [2*N-1:0] insn_buf_vld;

        $display(">> Fetch >>");
        bpu0.print_bpu;
        // insn_buf_vld = '0;
        // for (int cnt = 0; cnt < insn_buf.used; ++cnt)
        //     insn_buf_vld[(insn_buf.head + cnt) % (2*N)] = 1;
        // $display("insn_buf_vld: %b", insn_buf_vld);
        // for (int i = 0; i < N; ++i)
        //     $display("[%1d]: %1d", i, brch_prefix_cnt[i]);
        $display("flush: %b, flush_fb_base: %d, flush_fb_off", flush, flush_fb_base, flush_fb_off);
        $display("pc_reg: %d", bpu0.pc_reg);
        // $display("step: %b, pred:%b, wen_cnt:%d, pred_any: %b, pred_idx: %b",
        //     bpu0.step,
        //     bpu0.pred,
        //     bpu0.ghr0.wen_cnt,
        //     bpu0.pred_any,
        //     bpu0.pred_idx
        // );
        $display("d_out: {wen_cnt: %b, dat: [%x, %x]}", d_out.wen_cnt, d_out.dat[0], d_out.dat[1]);
        $display("brch: %b, pc_n: [%d, %d, %d]",
            brch,
            pc_n[0],
            pc_n[1],
            pc_n[2]
        );
        $display("cur: {fb_base: %d, off: %d}",
            cur.fb_base,
            cur.off
        );

        $display("f_cnt: %d, off_n: [%d, %d, %d], mem_out [%d, %d]",
            f_cnt,
            off_n[0][0],
            off_n[0][1],
            off_n[0][2],
            mem_out.PCdws[0],
            mem_out.PCdws[1]
        );

        // bpu0.ghr0.print_ghr;

        $display("bpu_upd: {en: %b, base: %d, fb_off: %d, take: %b, tgt: %d, md: %b}",
            btq_in.bp_upd.en,
            btq_in.bp_upd.dat.base,
            btq_in.bp_upd.dat.fb_off,
            btq_in.bp_upd.dat.take,
            btq_in.bp_upd.dat.tgt,
            btq_in.bp_upd.dat.md
        );
        bpu0.uftb0.print_uftb;
        // ftq0.print_ftq;
        $display("<< Fetch <<");
    endtask
`endif
endmodule


module stage_if_p4 (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,
    input   WADDR flush_PC,

    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   btq2fetch   btq_in,
    output  fetch2btq   btq_out,

    // execute
    input   execute2complete_bru cbru_in,

    input   rename2snap_bus snap_in,

    output  fetch2mem   mem_out,
    input   mem2fetch   mem_in
);
    WADDR PC_reg;       // base PC for this cycle
    WADDR [N:0] PC_n;  // PC_n[m] := next PC if we fetch "m" this cycle (inaccurate past the 1st branch)

    `CNT_TYPE(N)   free_scnt, used_scnt, f_cnt;
    logic [N-1:0] f_en;
    IF_ID_PKT [N-1:0]   f_dat;

    generate
    DWADDR PC_dw;
    assign d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);

    assign PC_n[0] = PC_reg;
    for (int i = 0; i < N; ++i)
        assign PC_n[i+1] = PC_reg + `UCAST_FIT(i+1);

    assign PC_dw = PC_reg[13:1]; // w -> dw
    assign mem_out.PCdws[0] = PC_dw;
    for (int i = 1; i < N; ++i)
        assign mem_out.PCdws[i] = PC_dw + `UCAST_FIT(i);
    endgenerate


    // Align
    BRANCH_MD [2*N-1:0] md_raw;
    INST      [2*N-1:0] inst_raw;
    BRANCH_MD [N-1:0] md;
    INST      [N-1:0] inst;
    generate
    for (genvar i = 0; i < N; ++i) begin
        for (genvar woff = 0; woff < 2; ++woff) begin
            assign md_raw   [2*i + woff] = mem_in.insn_md[i][woff];
            assign inst_raw [2*i + woff] = mem_in.data[i].word_level[woff];
        end
    end

    logic base_woff;
    assign base_woff = PC_reg[0];
    for (genvar i = 0; i < N; ++i) begin
        assign md[i]    = base_woff ? md_raw    [i+1] : md_raw  [i];
        assign inst[i]  = base_woff ? inst_raw  [i+1] : inst_raw[i];
    end
    endgenerate

    logic [N-1:0] brch, cond, call, ret;
    generate
    for (genvar i = 0; i < N; ++i) begin
        assign brch[i] = md[i].brch;
        assign cond[i] = md[i].cond;
        assign call[i] = md[i].call;
        assign ret[i]  = md[i].ret;
    end
    endgenerate

    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("PC_dws: [%x, %x]", mem_out.PCdws[0], mem_out.PCdws[1]);
    //         $display("mem_in: [%x, %x, %x, %x]",
    //         mem_in.data[0].word_level[0],
    //         mem_in.data[0].word_level[1],
    //         mem_in.data[1].word_level[0],
    //         mem_in.data[1].word_level[1]
    //         );
    //         $display("base_woff: %b", base_woff);

    //         $display("md_raw: %x, %x, %x, %x", md_raw[0], md_raw[1], md_raw[2], md_raw[3]);
    //         $display("inst_raw: %x, %x, %x, %x", inst_raw[0], inst_raw[1], inst_raw[2], inst_raw[3]);

    //         $display("md: %x, %x", md[0], md[1]);
    //         $display("inst: %x, %x", inst[0], inst[1]);
    //     end
    // end

    `CNT_TYPE(N) brch_lim_cnt;
    logic [N:0][`CNT_SIZE(N)-1:0] brch_prefix_cnt;
    fetch2bp bp_qry;
    bp2fetch bp_res;
    compactor #(
        .REQW(N),
        .GNTW(N)
    ) comp_brch (
        .req        (brch),
        .lim_cnt    (`MIN(btq_in.btq_rdy_scnt, bp_res.ghr_rdy_scnt)),
        .prefix_cnt (brch_prefix_cnt),
        .gnt_cnt    (brch_lim_cnt)
    );

    assign bp_qry = '{
        brch    : brch,
        cond    : cond,
        call    : call,
        ret     : ret,

        f_cnt   : f_cnt,
        // f_cnt   : f_cnt,
        PC_n    : PC_n,
        brch_prefix_cnt : brch_prefix_cnt,
        f_en    : f_en
    };

    logic [N-1:0] pred;
    WADDR [N-1:0] pred_tgt;
    assign pred     = bp_res.take;
    assign pred_tgt = bp_res.tgt;
    bp bp0 (
        .clock,
        .reset,
        .flush,
        .clmsk,
        .snap_in,

        .f_in       (bp_qry),
        .f_out      (bp_res),

        .cbru_in,

        .i_upd      (btq_in.bp_upd)
    );

    always_comb begin
        for (int unsigned i = 0; i < N; ++i) begin
            f_dat[i] = '{
                inst    : inst[i],
                PC      : PC_n[i],
                ras_snap: bp_res.ras_snap[i],
                btq_idx : '0 // filled below
            };
        end

        // handle btq output
        btq_out = '0;
        f_cnt = `MIN(brch_lim_cnt, free_scnt);
        f_cnt = `MIN(bp_res.lim_cnt, f_cnt);
        for (int i = 0; i < N; ++i)
            f_en[i] = i < f_cnt;
        /* NO LONGER.. IGNORE THIS:::: ^ want this f_en to be "pre BP f_en". bp_lim_cnt is redundant to BP
        since BP derives it in the first place */

        btq_out.en_cnt = brch_prefix_cnt[f_cnt];
        for (int i = 0; i < N; ++i) begin
            f_dat[i].btq_idx = btq_in.btq_idxs_n[brch_prefix_cnt[i]];

            btq_out.PC      [brch_prefix_cnt[i]] = PC_n[i];
            btq_out.pred    [brch_prefix_cnt[i]] = pred[i];
            btq_out.pred_tgt[brch_prefix_cnt[i]] = pred_tgt[i];
            btq_out.ret     [brch_prefix_cnt[i]] = ret[i];
            btq_out.cond    [brch_prefix_cnt[i]] = cond[i];
            btq_out.hash        [i]              = bp_res.hash[i];
            btq_out.ghr_base    [i]              = bp_res.ghr_base[i];
            btq_out.pred_bim    [i]              = bp_res.pred_bim[i];
            btq_out.pred_gshare [i]              = bp_res.pred_gshare[i];
        end

    end

    // always_ff @(posedge clock) begin
    //     $display("reset: %b, btq_out.en_cnt: %d, f_cnt: %d", reset, btq_out.en_cnt, f_cnt);
    //     $display("fluck: %b", fluck);
    //     for (int i = 0; i < N+1; ++i)
    //         $display("> brch_prefix_cnt[%1d]: %1d", i, brch_prefix_cnt[i]);
    // end


    fifo #(
        .DEPTH(2*N),
        .WIDTH($bits(IF_ID_PKT)),
        .NUM_RPORTS(N),
        .NUM_WPORTS(N),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) insn_buf (
        .clock,
        .reset,
        .flush,
        .wr_en_cnt  (f_cnt),
        .wr_data    (f_dat),
        .rd_en_cnt  (d_out.f_en_cnt),
        .rd_data    (d_out.f_dat),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;                    // initial PC value is 0 (the memory address where our program starts)
        end else if (flush) begin
            PC_reg <= flush_PC;    // update to a taken branch (does not depend on valid bit)...
        end else begin                      // ...or transition to next PC if valid
            PC_reg <= 
                f_cnt == 0    ? PC_reg :
                pred[f_cnt-1] ? pred_tgt[f_cnt-1] : PC_n[f_cnt];
        end
    end

`ifdef DEBUG
    task print_fetch;
        logic [2*N-1:0] insn_buf_vld;

        $display(">> Fetch >>");
        // insn_buf_vld = '0;
        // for (int cnt = 0; cnt < insn_buf.used; ++cnt)
        //     insn_buf_vld[(insn_buf.head + cnt) % (2*N)] = 1;
        // $display("insn_buf_vld: %b", insn_buf_vld);
        // for (int i = 0; i < N; ++i)
        //     $display("[%1d]: %1d", i, brch_prefix_cnt[i]);
        $display("flush: %b, flush_PC: 0x%x", flush, flush_PC);
        $display("d_out: {f_en_cnt: %b, dat: [%x, %x]}", d_out.f_en_cnt, d_out.f_dat[0], d_out.f_dat[1]);
        $display("btq_out.hash: [%b, %b], bp_res.hash: [%b, %b], bp_res.ghr_base: [%2d, %2d]",
            btq_out.hash[0],
            btq_out.hash[1],
            bp_res.hash[0],
            bp_res.hash[1],
            bp_res.ghr_base[0],
            bp_res.ghr_base[1]
        );
        $display("brch: %b, PC_n: [%x, %x, %x]",
            brch,
            PC_n[0],
            PC_n[1],
            PC_n[2]
        );
        bp0.ghr0.print_ghr;
        bp0.gshare0.print_gshare;
        $display("<< Fetch <<");
    endtask
`endif

endmodule // stage_if