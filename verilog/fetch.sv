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

localparam IQQ_SZ = 4;
localparam IRQ_SZ = 8;
typedef struct packed {
    DWADDR dw;
    `IDX_TYPE(IRQ_SZ) irq_idx;
} ICACHE_QUERY;

// typedef struct packed {
//     // general
//     MEM_BLOCK   blk;
//     WADDR       base;
//     logic [3:0] off;        // in-fb offset of word 0 in the cache line.

//     // branch-specific
//     WADDR       base_n;
//     logic       ft;         // fallthrough? else took a branch
//     logic       pred_w;     // ft ? <IGNORE? : word index of pred-taken branch


//     logic       hit;
//     logic [1:0] hit_slot;   // hit_slot[i] = hit FTB && hit slot i
//                             // Thus hit = |hit_slot


//     logic       is_tail;    // ft ? <IGNORE>: does pred-taken branch occupy tail slot?
//     logic       always_take;// ft ? <IGNORE>: " of pred-taken branch
//     BRANCH_MD   md;         // ft ? <IGNORE>: " of pred-tkaen branch
//                             // (selectively overwrite with icache results)
//     logic [GHR_LEN-1]       hash;
//     `IDX_TYPE(GHR_BUF_SZ)   ghr_base;
// } ICACHE_RESPONSE;

// icache response queue
module irq #(
    parameter DEPTH=IRQ_SZ,
    type PTR=`IDX_TYPE(DEPTH)
) (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,

    // write
    output  PTR [2:0]       wr_idxs_n,
    output  `CNT_TYPE(2)    rdy_scnt,
    input   `CNT_TYPE(2)    wen_cnt,
    input   pc_gen2ixq[1:0] wdat,

    // icache completions
    input   logic [1:0]     cen,
    input   PTR [1:0]       cidx,
    input   mem2fetch       cdat,

    // read
    output  `CNT_TYPE(2)    vld_scnt,
    input   `CNT_TYPE(2)    ren_cnt,
    output  ICACHE_RESPONSE [1:0]   rdat
);
    PTR [2:0] rd_idxs_n;

    logic [DEPTH-1:0] cpl;
    ICACHE_RESPONSE [DEPTH-1:0] state;

    `CNT_TYPE(2) used_scnt, free_scnt;

    ring_ctr #(
        .DEPTH(DEPTH),
        .RPORTS(2),
        .WPORTS(2),
        .FLUSH_MODE(FIFO_FLUSH_RESET)
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,

        .rd_en_cnt  (ren_cnt),
        .wr_en_cnt  (wen_cnt),

        .head       (),
        .tail       (),
        .rd_idxs_n,
        .wr_idxs_n,

        .used       (),
        .free       (),
        .used_scnt,
        .free_scnt
    );

    logic [1:0] rwin_cpl;
    logic       rwin_ncpl_any;
    `IDX_TYPE(2)rwin_ncpl_idx;
    generate
    for (genvar i = 0; i < 2; ++i) begin
        assign rwin_cpl[i]  = cpl[rd_idxs_n[i]];
        assign rdat[i]      = state[rd_idxs_n[i]];
    end
    endgenerate
    ffs #(
        .VECW(2)
    ) ff_ncpl (
        .i_vec(~rwin_cpl),
        .o_vld(rwin_ncpl_any),
        .o_idx(rwin_ncpl_idx)
    );

    assign rdy_scnt = free_scnt;

    assign vld_scnt = `MIN(
        used_scnt,
        rwin_ncpl_any ? rwin_ncpl_idx : 2
    );

    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display(">> IRQ");
    //         $display("vld_scnt: %d, rdy_scnt: %d", vld_scnt, rdy_scnt);
    //         $display("ren_cnt: %d, wen_cnt: %d", ren_cnt, wen_cnt);
    //         $display("rd[%d, %d, %d], wr[%d, %d, %d]",
    //             rd_idxs_n[0],
    //             rd_idxs_n[1],
    //             rd_idxs_n[2],
    //             wr_idxs_n[0],
    //             wr_idxs_n[1],
    //             wr_idxs_n[2]
    //         );
    //         for (int i = 0; i < IRQ_SZ; ++i)
    //             $display("irq[%d]: cpl: %b, dw: %d, off: [%d, %d], fmsk: %b, is_end: %b, blk: [%x, %x]",
    //                 i,
    //                 cpl[i],
    //                 state[i].dw,
    //                 state[i].off[0],
    //                 state[i].off[1],
    //                 state[i].fmsk,
    //                 state[i].is_end,
    //                 state[i].blk.word_level[0],
    //                 state[i].blk.word_level[1]
    //             );
    //     end
    // end

    always_ff @(posedge clock) begin
        if (reset) begin
            state   <= '0;
            cpl     <= '1;
        end else if (flush) begin
            cpl     <= '1;

        end else begin
            for (int i = 0; i < 2; ++i) begin
                int cur;
                if (!cen[i])
                    continue;
                cur = cidx[i];

                cpl  [cur]      <= 1;
                state[cur].blk  <= cdat.data[i];
                state[cur].md   <= cdat.insn_md[i];
            end

            for (int i = 0; i < `MIN(wen_cnt, 2); ++i) begin
                int cur;
                cur = wr_idxs_n[i];

                cpl  [cur]          <= 0;
                state[cur].dw       <=  wdat[i].dw;
                state[cur].off      <=  wdat[i].off;
                state[cur].fmsk     <=  wdat[i].fmsk;
                state[cur].is_end   <=  wdat[i].is_end;
            end

        end
    end

endmodule

module dcf (
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
    // bpu <-> ftq plumbing
    struct packed {
        logic       en;
        FTQ_ENTRY   dat;
    } bpu2ftq;
    struct packed {
        logic       rdy;
    } ftq2bpu;

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


    // ftq <-> pc_gen plumbing
    FTQ_ENTRY [1:0] ftq2pc_gen_dat;
    `CNT_TYPE(2)    ftq2pc_gen_vld_scnt;
    `CNT_TYPE(2)    pc_gen2ftq_ren_cnt;

    ftq ftq0 (
        .clock,
        .reset,
        .flush,

        .rdy        (ftq2bpu.rdy),
        .wen        (bpu2ftq.en),
        .wdat       (bpu2ftq.dat),

        .vld_scnt   (ftq2pc_gen_vld_scnt),
        .rdat       (ftq2pc_gen_dat),
        .ren_cnt    (pc_gen2ftq_ren_cnt)
    );

    pc_gen2ixq [1:0]pc_gen2ixq_dat;
    `CNT_TYPE(2)    pc_gen2ixq_wen_cnt;
    `CNT_TYPE(2)    ixq2pc_gen_rdy_scnt;

    FTQ_ENTRY [1:0] pc_gen2rrb_dat;
    `CNT_TYPE(2)    pc_gen2rrb_wen_cnt;
    `CNT_TYPE(2)    rrb2pc_gen_rdy_scnt;

    pc_gen pc_gen0 (
        .clock,
        .reset,
        .flush,

        .flush_fb_base,
        .flush_pc_off,

        .ftq_in_vld_scnt    (ftq2pc_gen_vld_scnt),
        .ftq_in_dat         (ftq2pc_gen_dat),
        .ftq_out_ren_cnt    (pc_gen2ftq_ren_cnt),

        .ixq_in_rdy_scnt    (ixq2pc_gen_rdy_scnt),
        .ixq_out_wen_cnt    (pc_gen2ixq_wen_cnt),
        .ixq_out_dat        (pc_gen2ixq_dat),

        .buf_in_rdy_scnt    (rrb2pc_gen_rdy_scnt),
        .buf_out_wen_cnt    (pc_gen2rrb_wen_cnt),
        .buf_out_dat        (pc_gen2rrb_dat)
    );

    // ""iqq""
    logic [2:0][`IDX_SIZE(IRQ_SZ)-1:0] irq_wr_idxs_n;
    struct packed {
        logic   [1:0]   vld;
        DWADDR  [1:0]   dw;
        logic   [1:0][`IDX_SIZE(IRQ_SZ)-1:0] irq_idx;
    } iqq, iqq_n;

    generate
    for (genvar i = 0; i < 2; ++i) begin
        assign iqq_n.vld    [i] = i < pc_gen2ixq_wen_cnt;

        assign iqq_n.dw     [i] = pc_gen2ixq_dat[i].dw;
        assign iqq_n.irq_idx[i] = irq_wr_idxs_n[i];
    end
    endgenerate

    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("iqq!");
    //         for (int i = 0; i < 2; ++i)
    //             $display("iqq[%d]: vld: %b, dw: %d, irq_idx: %d",
    //                 i,
    //                 iqq.vld[i],
    //                 iqq.dw[i],
    //                 iqq.irq_idx[i]
    //             );
    //     end
    // end

    struct packed {
        logic   [1:0]   vld;
        logic   [1:0][`IDX_SIZE(IRQ_SZ)-1:0] irq_idx;
        mem2fetch   mem_dat;
    } idat, idat_n;

    generate
    // assign mem_out.PCdws = iqq.dw;
    for (genvar i = 0; i < 2; ++i) begin
        assign mem_out.PCdws [i] = iqq.dw[i];
        assign idat_n.vld    [i] = iqq.vld[i];
        assign idat_n.irq_idx[i] = iqq.irq_idx[i];
    end
    assign idat_n.mem_dat = mem_in;
    endgenerate

    ICACHE_RESPONSE[1:0]irq2align_dat;
    `CNT_TYPE(2)        irq2align_vld_scnt;
    `CNT_TYPE(2)        align2irq_ren_cnt;

    irq irq0 (
        .clock,
        .reset,
        .flush,
        .clmsk  ('0),

        .wr_idxs_n  (irq_wr_idxs_n),
        .rdy_scnt   (ixq2pc_gen_rdy_scnt),  // TODO: change irq when has backpressure
        .wen_cnt    (pc_gen2ixq_wen_cnt),
        .wdat       (pc_gen2ixq_dat),

        .cen        (idat.vld),
        .cidx       (idat.irq_idx),
        .cdat       (idat.mem_dat),

        .vld_scnt   (irq2align_vld_scnt),
        .ren_cnt    (align2irq_ren_cnt),
        .rdat       (irq2align_dat)
    );

    FTQ_ENTRY[1:0]  rrb2align_dat;
    `CNT_TYPE(2)    align2rrb_ren_cnt;

    fifo #(
        .DEPTH(IRQ_SZ),
        .WIDTH($bits(FTQ_ENTRY)),
        .NUM_RPORTS(2),
        .NUM_WPORTS(2),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(72)
    ) rrb (
        .clock,
        .reset,
        .flush,

        // >> unused inputs
        .flush_snap ('0),
        .clmsk      ('0),
        .wr_bmask   ('0),
        // << unused inputs

        .wr_en_cnt  (pc_gen2rrb_wen_cnt),
        .wr_data    (pc_gen2rrb_dat),
        .rd_en_cnt  (align2rrb_ren_cnt),
        .rd_data    (rrb2align_dat),
        .free_scnt  (rrb2pc_gen_rdy_scnt),
        .used_scnt  ()
    );

    IF_ID_PACKET[3:0]   align2ibuf_dat;
    `CNT_TYPE(4)        align2ibuf_wen_cnt;
    `CNT_TYPE(4)        ibuf2align_rdy_scnt;

    align align0 (
        .rrb_in_dat     (rrb2align_dat),
        .rrb_out_ren_cnt(align2rrb_ren_cnt),

        .irq_in_vld_scnt(irq2align_vld_scnt),
        .irq_in_dat     (irq2align_dat),
        .irq_out_ren_cnt(align2irq_ren_cnt),

        .btq_in,
        .btq_out,

        .ibuf_in_rdy_scnt   (ibuf2align_rdy_scnt),
        .ibuf_out_wen_cnt   (align2ibuf_wen_cnt),
        .ibuf_out_dat       (align2ibuf_dat)
    );


    `CNT_TYPE(N) used_scnt;
    assign d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);
    fifo #(
        .DEPTH(4*N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(N),
        .NUM_WPORTS(4),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(48)
    ) insn_buf (
        .clock,
        .reset,
        .flush,

        // >> unused inputs
        .flush_snap ('0),
        .clmsk      ('0),
        .wr_bmask   ('0),
        // << unused inputs

        .wr_en_cnt  (align2ibuf_wen_cnt),
        .wr_data    (align2ibuf_dat),
        .rd_en_cnt  (d_out.f_en_cnt),
        .rd_data    (d_out.f_dat),
        .free_scnt  (ibuf2align_rdy_scnt),
        .used_scnt  (used_scnt)
    );

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            iqq.vld <= '0;
            idat.vld<= '0;
            // iqq     <= '0;
            // idat    <= '0;

        end else begin
            iqq     <= iqq_n;
            idat    <= idat_n;

        end

    end

endmodule

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
        FTQ_ENTRY [1:0] rdat;
        `CNT_TYPE(2)    vld_scnt, ren_cnt;
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
    IF_ID_PACKET [N-1:0]   f_dat;
        // BTQ limit
    `CNT_TYPE(N) brch_lim_cnt;
    logic [N:0][`CNT_SIZE(N)-1:0] brch_prefix_cnt;
    compactor #(
        .REQW(N),
        .GNTW(N)
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
        for (int unsigned i = 0; i < N; ++i) begin
            f_dat[i] = '{
                inst    : inst[i],
                PC      : pc_n[i],
                ras_snap: '0, // FIXME
                btq_idx : '0 // filled below
            };
        end

        btq_out = '0;
        btq_out.en_cnt = brch_prefix_cnt[f_cnt];

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
        .WIDTH($bits(IF_ID_PACKET)),
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
        logic [2*N-1:0] insn_buf_vld;

        $display(">> Fetch >>");
        bpu0.print_bpu;
        // insn_buf_vld = '0;
        // for (int cnt = 0; cnt < insn_buf.used; ++cnt)
        //     insn_buf_vld[(insn_buf.head + cnt) % (2*N)] = 1;
        // $display("insn_buf_vld: %b", insn_buf_vld);
        // for (int i = 0; i < N; ++i)
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
            off_n[0][0],
            off_n[0][1],
            off_n[0][2],
            mem_out.PCdws[0],
            mem_out.PCdws[1]
        );

        // bpu0.ghr0.print_ghr;

        $display("bpu_upd: {en: %b, base: %d, pc_off: %d, take: %b, tgt: %d, md: %b}",
            btq_in.bp_upd.en,
            btq_in.bp_upd.dat.base,
            btq_in.bp_upd.dat.pc_off,
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
