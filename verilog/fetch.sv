/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_if.sv                                         //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

// decoupled fetch
module fetch (
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
    input   logic [3:0] flush_pc_off,

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
        logic       vld;
        FTQ_ENTRY   rdat;
        logic       ren;
    } ftq_io;

    bpu bpu0 (
        .clock,
        .reset,

        .flush,
        .flush_fb_base,
        .flush_pc_off,
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

        .vld    (ftq_io.vld),
        .rdat   (ftq_io.rdat),
        .ren    (ftq_io.ren)
    );

    // Form indices: fb offsets, PCs, block DWs
    logic [`N:0][3:0]   off_n;
    WADDR [`N:0]        pc_n;
    always_comb begin
        for (int i = 0; i < `N+1; ++i)
            off_n[i] = cur.off + i;

        for (int i = 0; i < `N+1; ++i)
            pc_n[i] = cur.fb_base + off_n[i];

        for (int i = 0; i < `N; ++i) // FIXME: These are mem blocks btw. Only works for `N = 2;
            mem_out.PCdws[i] = pc_n[0][13:1] + i; // w -> dw
    end

    // Align
    BRANCH_MD [2*`N-1:0] md_raw;
    INST      [2*`N-1:0] inst_raw;
    BRANCH_MD [`N-1:0] md;
    INST      [`N-1:0] inst;
    generate
    for (genvar i = 0; i < `N; ++i) begin
        for (genvar woff = 0; woff < 2; ++woff) begin
            assign md_raw   [2*i + woff] = mem_in.insn_md[i][woff];
            assign inst_raw [2*i + woff] = mem_in.data[i].word_level[woff];
        end
    end

    logic base_woff;
    assign base_woff = pc_n[0];
    for (genvar i = 0; i < `N; ++i) begin
        assign md[i]    = base_woff ? md_raw    [i+1] : md_raw  [i];
        assign inst[i]  = base_woff ? inst_raw  [i+1] : inst_raw[i];
    end
    endgenerate

    logic [`N-1:0] brch, cond, call, ret, jalr;
    generate
    for (genvar i = 0; i < `N; ++i) begin
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
    logic [`N-1:0] is_fb_end;
    logic [$clog2(`N)-1:0] fb_end_any, fb_end_idx;
    generate
    for (genvar i = 0; i < `N; ++i)
        assign is_fb_end[i] = off_n[i] == r.off;
    endgenerate

    ffs #(
        .VECW(`N)
    ) ff_end (
        .i_vec(is_fb_end),
        .o_vld(fb_end_any),
        .o_idx(fb_end_idx)
    );

        // Fetch-FSM: consume FTQ entry
    logic [$clog2(`N):0] fsm_lim_cnt, f_cnt;
    always_comb begin
        fsm_lim_cnt =
            !ftq_io.vld ? 0 :
            fb_end_any  ? fb_end_idx + 1 :
            `N;

        cur_n       = cur;
        ftq_io.ren  = 0;
        if (ftq_io.vld && fb_end_any && (fsm_lim_cnt == f_cnt)) begin
            // finished consuming FTQ entry (entry is valid and reached FB end)
            cur_n = '{
                fb_base : r.base_n, // advance FB base
                off     : 0         // reset in-fb offset
            };

            // signal consume to FTQ
            ftq_io.ren = 1;

        end else
            cur_n.off = off_n[f_cnt];

    end

    // Handle count
    logic [$clog2(`N):0]    free_scnt, used_scnt;
    IF_ID_PACKET [`N-1:0]   f_dat;
        // BTQ limit
    logic [$clog2(`N):0] brch_lim_cnt;
    logic [`N:0][$clog2(`N):0] brch_prefix_cnt;
    compactor #(
        .REQW(`N),
        .GNTW(`N)
    ) comp_brch (
        .req        (brch),
        .lim_cnt    (btq_in.btq_rdy_scnt),
        .prefix_cnt (brch_prefix_cnt),
        .gnt_cnt    (brch_lim_cnt)
    );

    always_comb begin
        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);
        f_cnt = `MIN(fsm_lim_cnt, `MIN(brch_lim_cnt, free_scnt));
    end

    always_comb begin
        for (int unsigned i = 0; i < `N; ++i) begin
            f_dat[i] = '{
                inst    : inst[i],
                PC      : pc_n[i],
                ras_snap: '0, // FIXME
                btq_idx : '0 // filled below
            };
        end

        btq_out = '0;
        btq_out.en_cnt = brch_prefix_cnt[f_cnt];

        for (int i = 0; i < `N; ++i) begin
            f_dat[i].btq_idx = btq_in.btq_idxs_n[brch_prefix_cnt[i]];

            btq_out.is_tail [brch_prefix_cnt[i]] = (r.pred_idx == 1) && (off_n[i] == r.off);
                /*
                FIXME (unsure): Probably not necessary to check for "off_geq_tail",
                i.e. (r.pred_idx == 1) && (off_n[i] >= r.off), because branches after (>)
                the tail slot would not even be in the same fetch block?
                */
            btq_out.PC      [brch_prefix_cnt[i]] = pc_n[i];
            btq_out.off     [brch_prefix_cnt[i]] = off_n[i];
            btq_out.pred    [brch_prefix_cnt[i]] = !r.ft && (off_n[i] == r.off);
            btq_out.pred_tgt[brch_prefix_cnt[i]] = r.base_n;
            btq_out.md      [brch_prefix_cnt[i]] = '{
                cond : cond[i],
                call : call[i],
                ret  : ret[i],
                jalr : jalr[i]
            }; // TODO: fix RAS if pred ret but not ret (likewise for call)

            btq_out.hash        [i]              = '0; // FIXME
            btq_out.ghr_base    [i]              = '0; // FIXME
            btq_out.pred_bim    [i]              = '0; // FIXME
            btq_out.pred_gshare [i]              = '0; // FIXME
        end
    end

    fifo #(
        .DEPTH(2*`N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) pc_buf (
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
        if (reset)
            cur <= '0;

        else if (flush)
            cur <= '{
                fb_base : flush_fb_base,
                off     : flush_pc_off
            };

        else
            cur <= cur_n;

    end

`ifdef DEBUG
    task print_fetch;
        logic [2*`N-1:0] insn_buf_vld;

        $display(">> Fetch >>");
        bpu0.print_bpu;
        // insn_buf_vld = '0;
        // for (int cnt = 0; cnt < insn_buf.used; ++cnt)
        //     insn_buf_vld[(insn_buf.head + cnt) % (2*`N)] = 1;
        // $display("insn_buf_vld: %b", insn_buf_vld);
        // for (int i = 0; i < `N; ++i)
        //     $display("[%1d]: %1d", i, brch_prefix_cnt[i]);
        $display("flush: %b, flush_fb_base: %d, flush_pc_off", flush, flush_fb_base, flush_pc_off);
        $display("pc_reg: %d", bpu0.pc_reg);
        // $display("step: %b, pred:%b, f_en_cnt:%d, pred_any: %b, pred_idx: %b",
        //     bpu0.step,
        //     bpu0.pred,
        //     bpu0.ghr0.f_en_cnt,
        //     bpu0.pred_any,
        //     bpu0.pred_idx
        // );
        $display("d_out: {f_en_cnt: %b, dat: [%x, %x]}", d_out.f_en_cnt, d_out.f_dat[0], d_out.f_dat[1]);
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
            off_n[0],
            off_n[1],
            off_n[2],
            mem_out.PCdws[0],
            mem_out.PCdws[1]
        );

        // bpu0.ghr0.print_ghr;
        // ftq0.print_ftq;

        $display("bpu_upd: {en: %b, base: %d, pc_off: %d, take: %b, tgt: %d, md: %b}",
            btq_in.bp_upd.en,
            btq_in.bp_upd.dat.base,
            btq_in.bp_upd.dat.pc_off,
            btq_in.bp_upd.dat.take,
            btq_in.bp_upd.dat.tgt,
            btq_in.bp_upd.dat.md
        );
        bpu0.uftb0.print_uftb;
        $display("<< Fetch <<");
    endtask
`endif

endmodule
