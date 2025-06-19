`include "sys_defs.svh"

/* NOTE:
Since the FTQ_ENTRY does not store the current base (it only stores base_n),
it is *vital* that upon reset, flush, or–– in the future–– steer, the BPU and
pc_gen are both reset to exact same base. Maybe use a runtime assertion like this?:

property p_never_diverge;
  @(posedge clock)
    disable iff (reset)
    pc_gen.cur.base == $past(BPU.fb_base);
endproperty

TODO: Rename "buf" to re-read FTQ (since FTQ entries are being "re-read" at align)
*/
module pc_gen #(
    parameter MAX_W_PER_FB  = 16,// maximum span of a fetch block / ftq entry, in words
    parameter W_PER_DW      = 2, // num words per double-word / cache line
    parameter NUM_DW        = 2, // num double words we can process per cycle
    parameter NUM_FTQ       = 2, // num FTQ entries we can process per cycle
    type FB_OFF=`IDX_TYPE(MAX_W_PER_FB),
    localparam  NUM_W       = NUM_DW*W_PER_DW
) (
    input   clock,
    input   reset,
    input   flush,

    input   WADDR       flush_fb_base,
    input   logic [3:0] flush_pc_off,
`ifdef PC_GEN_TEST_MODE
    input   struct packed {
        logic [3:0] off;
        WADDR       base;
        logic       inbuf;
    } reset_val,
`endif

    // ftq
    input   `CNT_TYPE(2)    ftq_in_vld_scnt,
    input   FTQ_ENTRY[1:0]  ftq_in_dat,
    output  `CNT_TYPE(2)    ftq_out_ren_cnt,

    // irq / iqq
    // FIXME: these ixq_out lines should be folded into a dat struct
    input   `CNT_TYPE(2)    ixq_in_rdy_scnt, // = `MIN(iqq_*, irq_*)
    output  `CNT_TYPE(2)    ixq_out_wen_cnt,
    output  FB_OFF[1:0][1:0]ixq_out_off,
    output  DWADDR [1:0]    ixq_out_dw,
    output  logic[1:0][1:0] ixq_out_fmsk,
    output  logic[1:0][1:0] ixq_out_is_end,

    // FTQ buffer
    input   `CNT_TYPE(2)    buf_in_rdy_scnt,
    output  `CNT_TYPE(2)    buf_out_wen_cnt,
    output  FTQ_ENTRY[1:0]  buf_out_dat
);
    localparam FB_OFF off_rst = '0;
    localparam WADDR base_rst = '0;
    localparam logic inbuf_rst = 0;

    struct packed {
        FB_OFF  off;
        WADDR   base;
        logic   inbuf; // FTQ entry allocated in buf?
    } cur;

    // Form indices: fb offsets, PCs, block DWs
    logic   [NUM_FTQ-1:0] base_woff;            // index: (ftq).
    FB_OFF  [NUM_FTQ-1:0][NUM_W:0]  nal_off_n;  // index: (ftq, word).
    logic   [NUM_FTQ-1:0][NUM_W-1:0]nal_is_end; // index: (ftq, word). nal = not cache line aligned
    generate
    assign base_woff[0] = cur.base[0] ^ cur.off[0]; // 1 bit add
    assign base_woff[1] = ftq_in_dat[0].base_n[0];

    assign nal_off_n[0][0] = cur.off;
    assign nal_off_n[1][0] = 0;
    for (genvar w = 1; w <= NUM_W; ++w) begin
        assign nal_off_n[0][w] = cur.off + `UCAST_FIT(w);
        assign nal_off_n[1][w] = w;
    end

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar w = 0; w < NUM_W; ++w) begin
            assign nal_is_end[e][w] = ftq_in_dat[e].off == nal_off_n[e][w];
        end
    end
    endgenerate


    FB_OFF  [NUM_FTQ-1:0][NUM_W:0]off_n;
    FB_OFF  [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] blk_off_n;
    logic   [NUM_FTQ-1:0][NUM_W-1:0]is_end_flat, fmsk_flat;
    logic   [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] is_end, fmsk;
    generate
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign off_n[e][0] = base_woff[e]
            ? '0
            : nal_off_n[e][0];

        for (genvar w = 1; w <= NUM_W; ++w) begin
            // assign off_n[e][NUM_W:1] = nal_off_n[e][!base_woff[e] +: NUM_W];
            assign off_n[e][w] = base_woff[e]
                ? nal_off_n[e][w-1]
                : nal_off_n[e][w];
        end

    end

    logic   [NUM_FTQ-1:0][NUM_W-1:0] align_msk, after_end;
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign align_msk[e]     = {NUM_W{1'b1}} << base_woff[e];
        assign is_end_flat[e]   = nal_is_end[e] << base_woff[e];
    end

    for (genvar e = 0; e < NUM_FTQ; ++e)
        assign after_end[e] = (after_end[e] | is_end_flat[e]) << 1;

    assign fmsk_flat = align_msk & ~after_end;

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar b = 0; b < NUM_DW; ++b) begin
            assign fmsk  [e][b] = fmsk_flat  [e][W_PER_DW*b +: W_PER_DW];
            assign is_end[e][b] = is_end_flat[e][W_PER_DW*b +: W_PER_DW];
            assign blk_off_n[e][b] = off_n[e][W_PER_DW*b +: W_PER_DW];
        end
    end

    logic   [NUM_FTQ-1:0][NUM_DW-1:0] blk_has_end;
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar b = 0; b < NUM_DW; ++b) begin
            assign blk_has_end[e][b]= |is_end[e][b];
        end
    end
    endgenerate

    DWADDR  [NUM_FTQ-1:0][NUM_DW-1:0] dws;
    generate
    WADDR   [NUM_FTQ-1:0] start_pc;
    assign start_pc[0] = cur.base + cur.off;
    assign start_pc[1] = ftq_in_dat[0].base_n;

    assign dws[0][0] = start_pc[0][13:1];
    assign dws[0][1] = start_pc[0][13:1] + `UCAST_FIT(1);
    assign dws[1][0] = start_pc[1][13:1];
    assign dws[1][1] = start_pc[1][13:1] + `UCAST_FIT(1);
    endgenerate

    FB_OFF  [NUM_FTQ-1:0][NUM_DW-1:0] pos_blk_off;
    generate
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar b = 0; b < NUM_DW; ++b) begin
            assign pos_blk_off[e][b] = off_n[e][W_PER_DW*(b+1)];
        end
    end
    endgenerate

    logic   ftq1_vld;
    assign  ftq1_vld = ftq_in_vld_scnt[1];

    logic bhe00;
    logic bhe01;
    logic bhe10;
    logic bhe11;
    assign bhe00    = blk_has_end[0][0];
    assign bhe01    = blk_has_end[0][1];
    assign bhe10    = blk_has_end[1][0];
    assign bhe11    = blk_has_end[1][1];

    logic merge_l0, merge_l1;
    assign merge_l0 = ftq1_vld && bhe00 && !is_end[0][0][W_PER_DW-1] && ftq_in_dat[0].ft;
    assign merge_l1 = ftq1_vld && bhe01 && !is_end[0][1][W_PER_DW-1] && ftq_in_dat[0].ft;

    logic   iss_any;    // can issue any request?
    logic   iss_idx;    // index of last issuable request, if any
    assign  iss_any = ftq_in_vld_scnt != 0;
    always_comb begin
        iss_idx = 0;
        unique case (1'b1)
        merge_l0  &  bhe10: iss_idx = 0;
        merge_l0  & ~bhe10: iss_idx = 1;
        ~merge_l0 &  bhe00: iss_idx = ftq1_vld;
        ~merge_l0 & ~bhe00: iss_idx = 1;
        endcase
    end

    logic   [NUM_DW-1:0] adv_bidx;  // ignore corr. idx aft_bidx if not set
    logic   [NUM_DW-1:0] adv_blk;   // ignore corr. idx aft_blk if not set
    logic   [NUM_DW-1:0][`IDX_SIZE(NUM_FTQ)-1:0]  aft_bidx; // latest base idx we are going past
    logic   [NUM_DW-1:0][`IDX_SIZE(NUM_DW)-1:0]   aft_blk;  // latest block idx we are going past
    // ^^ assuming NUM_FTQ = 2, NUM_DW = 2, then these are just:
    // logic    [NUM_DW-1:0] aft_bidx;
    // logic    [NUM_DW-1:0] aft_blk;

    // ------------------------------------------------------------------
    // adv_*[0]
    // ------------------------------------------------------------------
    always_comb begin
        adv_bidx[0] = 0;
        aft_bidx[0] = 0;
        adv_blk [0] = 0;
        aft_blk [0] = 0;

        unique case (1'b1)
        bhe00 & ~merge_l0: begin
            adv_bidx[0] = 1;
            aft_bidx[0] = 0;

            adv_blk [0] = 0;
        end

        bhe00 &  merge_l0: begin
            adv_bidx[0] = 1;
            aft_bidx[0] =  bhe10;

            adv_blk [0] = ~bhe10;
            aft_blk [0]= 0;
        end

        default: begin
            adv_bidx[0] = 0;

            adv_blk [0] = 1;
            aft_blk [0] = 0;
        end
        endcase
    end

    // ------------------------------------------------------------------
    // adv_*[1]
    // ------------------------------------------------------------------
    always_comb begin
        adv_bidx[1]= 0;
        adv_blk [1]= 0;
        aft_bidx[1]= 0;
        aft_blk [1]= 0;

        unique case (1'b1)
        merge_l0  &  bhe10:; // ignore. Can't issue 2

        merge_l0  & ~bhe10 &  bhe11: begin
            adv_bidx[1] = 1;
            aft_bidx[1] = 1; // base adv by 2

            adv_blk [1] = 0;
        end

        merge_l0  & ~bhe10 & ~bhe11: begin
            adv_bidx[1] = 1;
            aft_bidx[1] = 0; // base adv by 1

            adv_blk [1] = 1;
            aft_blk [1] = 1; // blk  adv by 2
        end

        (~merge_l0 & merge_l1) &  bhe10: begin
            // assert(~bhe00);
            adv_bidx[1] = 1;
            aft_bidx[1] = 1; // base adv by 2

            adv_blk [1] = 0;
        end

        (~merge_l0 & merge_l1) & ~bhe10: begin
            // assert(~bhe00);
            adv_bidx[1] = 1;
            aft_bidx[1] = 0; // base adv by 1

            adv_blk [1] = 1;
            aft_blk [1] = 0; // blk  adv by 1
        end

        (~merge_l0 & ~merge_l1) & ~bhe00 &  bhe01: begin
            adv_bidx[1] = 1;
            aft_bidx[1] = 0;

            adv_blk [1] = 0;
        end

        (~merge_l0 & ~merge_l1) & ~bhe00 & ~bhe01: begin
            adv_bidx[1] = 0;

            adv_blk [1] = 1;
            aft_blk [1] = 1; // blk  adv by 2
        end

        (~merge_l0 & ~merge_l1) &  bhe00 &  bhe10: begin
            adv_bidx[1] = 1;
            aft_bidx[1] = 1;

            adv_blk [1] = 0;
        end

        (~merge_l0 & ~merge_l1) &  bhe00 & ~bhe10: begin
            adv_bidx[1] = 1;
            aft_bidx[1] = 0;

            adv_blk [1] = 1;
            aft_blk [1] = 0;
        end
        endcase
    end

    function FB_OFF [W_PER_DW-1:0] merge_off(
        FB_OFF[W_PER_DW-1:0] aoff, boff,
        logic [W_PER_DW-1:0] amsk, bmsk
    );
        FB_OFF [W_PER_DW-1:0] rv;
        for (int w = 0; w < W_PER_DW; ++w)
            rv[w] = (amsk[w] ? aoff[w] : '0) | (bmsk[w] ? boff[w] : '0);
        return rv;
    endfunction

    logic mer_l0, mer_l1;
    assign mer_l0 = bhe00 && !is_end[0][0][W_PER_DW-1] && ftq_in_dat[0].ft;
    assign mer_l1 = bhe01 && !is_end[0][1][W_PER_DW-1] && ftq_in_dat[0].ft;

    // Merging data
    FB_OFF  [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] mer_blk_off_n;
    logic   [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] mer_is_end, mer_fmsk;
    FB_OFF  [W_PER_DW-1:0] fuse_blk_off_n;
    logic   [W_PER_DW-1:0] fuse_is_end, fuse_fmsk;

    // Only 10 may need merging
    assign mer_blk_off_n[0]     = blk_off_n[0];
    assign mer_blk_off_n[1][0]  =
        merge_off(
            blk_off_n[1][0], fuse_blk_off_n,
            fmsk     [1][0], fuse_fmsk
        );
    assign mer_blk_off_n[1][1]  = blk_off_n[1][1];

    assign mer_is_end[0]        = is_end[0];
    assign mer_is_end[1][0]     = is_end[1][0] | fuse_is_end;
    assign mer_is_end[1][1]     = is_end[1][1];

    assign mer_fmsk[0]          = fmsk[0];
    assign mer_fmsk[1][0]       = fmsk[1][0] | fuse_fmsk;
    assign mer_fmsk[1][1]       = fmsk[1][1];
    always_comb begin
        unique case (1'b1)
        merge_l0: begin
            fuse_blk_off_n  = blk_off_n [0][0];
            fuse_is_end     = is_end    [0][0];
            fuse_fmsk       = fmsk      [0][0];
        end

        merge_l1: begin
            fuse_blk_off_n  = blk_off_n [0][1];
            fuse_is_end     = is_end    [0][1];
            fuse_fmsk       = fmsk      [0][1];
        end

        default: begin
            fuse_blk_off_n  = '0;
            fuse_is_end     = '0;
            fuse_fmsk       = '0;
        end
        endcase
    end


    logic e0, e1;
    logic b0, b1;
    assign e0 = merge_l0;
    assign b0 = 0;

    always_comb begin
        // e1 = !(merge_l0 && bhe00 && merge_l1);

        unique case (1'b1)
        merge_l0: begin
            // case 1:  bhe10 -> cant issue 2 (dont care)
            // case 2: ~bhe10 -> e1=1, b1=1
            e1 = 1;
            b1 = 1;
        end

        ~merge_l0 &  bhe00: begin
            e1 = 1;
            b1 = 0;
        end

        ~merge_l0 & ~bhe00 & ~merge_l1: begin
            e1 = 0;
            b1 = 1;
        end

        ~merge_l0 & ~bhe00 &  merge_l1: begin
            e1 = 1;
            b1 = 0;
        end
        endcase
    end

    assign ixq_out_dw[0]    = dws           [e0][b0];
    assign ixq_out_off[0]   = mer_blk_off_n [e0][b0];
    assign ixq_out_fmsk[0]  = mer_fmsk      [e0][b0];
    assign ixq_out_is_end[0]= mer_is_end    [e0][b0];

    assign ixq_out_dw[1]    = dws           [e1][b1];
    assign ixq_out_off[1]   = mer_blk_off_n [e1][b1];
    assign ixq_out_fmsk[1]  = mer_fmsk      [e1][b1];
    assign ixq_out_is_end[1]= mer_is_end    [e1][b1];

    `CNT_TYPE(NUM_FTQ) buf_lim_cnt;
    logic [NUM_DW-1:0] req_buf;
    logic [NUM_DW:0][`CNT_SIZE(NUM_FTQ)-1:0] buf_prefix_cnt;
    compactor #(
        .REQW(NUM_DW),
        .GNTW(NUM_FTQ)
    ) comp_buf_req (
        .req        (req_buf),
        .lim_cnt    (buf_in_rdy_scnt),
        .prefix_cnt (buf_prefix_cnt),
        .gnt_cnt    (buf_lim_cnt)
    );

    assign buf_out_dat[0] = !cur.inbuf ? ftq_in_dat[0] : ftq_in_dat[1];
    assign buf_out_dat[1] = ftq_in_dat[1];

    assign req_buf[0] = !cur.inbuf || adv_bidx[0];
    assign req_buf[1] = !cur.inbuf && adv_bidx[1];
    always_comb begin
        logic dwidx;

        /*FIXME:
        We may actually request up to 3 buffer slots per cycle
        ftq 0 is !inbuf AND adv_base == 2

        Actually maybe this is fine. inbuf is zeroed when adv_base_v == 2.
        We don't even access to the 3rd ftq entry this cycle, so we will never
        be able to push it to the reread queue.
        */

        ixq_out_wen_cnt = `MIN(buf_lim_cnt, `MIN(ftq_in_vld_scnt, ixq_in_rdy_scnt));

        dwidx = ixq_out_wen_cnt[1];
        ftq_out_ren_cnt = (ixq_out_wen_cnt == 0 || !adv_bidx[dwidx])
            ? 0
            : aft_bidx[dwidx] + 1;

        buf_out_wen_cnt = buf_prefix_cnt[ixq_out_wen_cnt];
    end

    WADDR [NUM_FTQ-1:0] base_n;
    assign base_n[0] = ftq_in_dat[0].base_n;
    assign base_n[1] = ftq_in_dat[1].base_n;

    always_ff @(posedge clock) begin
        logic dwidx, basv, blkv;

        if (reset)
`ifndef PC_GEN_TEST_MODE
            cur <= '{
                off : off_rst,
                base: base_rst,
                inbuf:inbuf_rst
            };
`else
            cur <= reset_val;
`endif
        else if (flush)
            cur <= '{
                off  : flush_pc_off,
                base : flush_fb_base,
                inbuf: 0
            };

        else if (ixq_out_wen_cnt != 0) begin
            dwidx = ixq_out_wen_cnt[1];

            basv = aft_bidx [dwidx];
            blkv = aft_blk  [dwidx];

            if (adv_bidx[dwidx])
                cur.base    <= base_n[basv];
            if (adv_blk [dwidx])
                cur.off     <= pos_blk_off[adv_bidx[dwidx]][blkv]; // assert !aft_bidx[dwidx]

            // adv_blk is high IFF we do not advance 2 bases
            assert(adv_blk[dwidx] ? !(adv_bidx[dwidx] && basv) : 1) else $fatal;
            assert((adv_bidx[dwidx] && basv) ? !adv_blk[dwidx] : 1) else $fatal;

            cur.inbuf   <= !(adv_bidx[dwidx] && basv);
        end

        if (!reset) begin
            $display("FOGET: base: %d, off: %d", cur.base, cur.off);
            $display("dwidx: %b, basv: %b, blkv: %b", dwidx, basv, blkv);
            $display("0-bidx: [adv: %b, aft: %b], 1-bidx: [adv: %b, aft: %b]",
                adv_bidx[0],
                aft_bidx[0],
                adv_bidx[1],
                aft_bidx[1]
            );
            $display("0-blk:  [adv: %b, aft: %b], 1-blk:  [adv: %b, aft: %b]",
                adv_blk[0],
                aft_blk[0],
                adv_blk[1],
                aft_blk[1]
            );
            for (int i = 0; i < 4; ++i) begin
                logic x, y;
                x = i / 2;
                y = i % 2;
                $display("pos_blk_off[%d][%d]: %d",
                    x,
                    y,
                    pos_blk_off[x][y]
                );
            end
            print_pc_gen;
        end
    end

    task print_pc_gen;
        // $display("ftq_in_dat[*].off: [%d, %d]",
        //     ftq_in_dat[0].off,
        //     ftq_in_dat[1].off,
        // );

        $display("(e0, b0) = (%b, %b), (e1, b1) = (%b, %b)", e0, b0, e1, b1);
        $display("merge_l0: %b, merge_l1: %b", merge_l0, merge_l1);
        $display("bhe00: %b, bhe01: %b, bhe10: %b, bhe11: %b", bhe00, bhe01, bhe10, bhe11);

        $display("mer fmsk: [%b, %b]",
            mer_fmsk[0],
            mer_fmsk[1]
        );
        $display("mer is_end: [%b, %b]",
            mer_is_end[0],
            mer_is_end[1]
        );

        $display("nal_off_n: [[%d, %d, %d, %d, %d], [%d, %d, %d, %d, %d]]",
            nal_off_n[0][0],
            nal_off_n[0][1],
            nal_off_n[0][2],
            nal_off_n[0][3],
            nal_off_n[0][4],
            nal_off_n[1][0],
            nal_off_n[1][1],
            nal_off_n[1][2],
            nal_off_n[1][3],
            nal_off_n[1][4]
        );

        // $display("nal_is_end: %b", nal_is_end);

        $display("ftq[0]: base_woff: %b, align_msk: %b, fmsk: %b, off_n: [%d, %d, %d, %d, %d], is_end_flat: %b",
            base_woff[0],
            align_msk[0],
            fmsk_flat[0],
            off_n[0][0],
            off_n[0][1],
            off_n[0][2],
            off_n[0][3],
            off_n[0][4],
            is_end_flat[0]
        );

        $display("ftq[1]: base_woff: %b, align_msk: %b, fmsk: %b, off_n: [%d, %d, %d, %d, %d], is_end_flat: %b",
            base_woff[1],
            align_msk[1],
            fmsk_flat[1],
            off_n[1][0],
            off_n[1][1],
            off_n[1][2],
            off_n[1][3],
            off_n[1][4],
            is_end_flat[1]
        );

        $display("ftq_out: ren_cnt: %d",
            ftq_out_ren_cnt
        );

        $display("ixq_out: wen_cnt = %d, dw = [%d, %d], off = [[%d, %d], [%d, %d]], fmsk = %b, is_end = %b",
            ixq_out_wen_cnt,
            ixq_out_dw[0],
            ixq_out_dw[1],
            ixq_out_off[0][0],
            ixq_out_off[0][1],
            ixq_out_off[1][0],
            ixq_out_off[1][1],
            ixq_out_fmsk,
            ixq_out_is_end
        );

        $display("buf_out: wen_cnt = %d, [{base_n: %d, ft: %b, off: %d}, {base_n: %d, ft: %b, off: %d}]\n",
            buf_out_wen_cnt,
            buf_out_dat[0].base_n,
            buf_out_dat[0].ft,
            buf_out_dat[0].off,
            buf_out_dat[1].base_n,
            buf_out_dat[1].ft,
            buf_out_dat[1].off
        );

        $display("adv_bidx: [%b, %b] |||| aft_bidx: [%b, %b]",
            adv_bidx[0],
            adv_bidx[1],
            aft_bidx[0],
            aft_bidx[1]
        );

        $display("adv_blk: [%b, %b] |||| aft_blk: [%b, %b]",
            adv_blk[0],
            adv_blk[1],
            aft_blk[0],
            aft_blk[1]
        );

        // $display("adv_blk: [%d, %d, %d] -> %d",
        //     adv_blk[0],
        //     adv_blk[1],
        //     adv_blk[2],
        //     adv_blk_v
        // );

        $display("pos_blk_off: [\n[%d, %d],\n[%d, %d]] -> %d",
            pos_blk_off[0][0],
            pos_blk_off[0][1],
            // pos_blk_off[0][2],
            pos_blk_off[1][0],
            pos_blk_off[1][1],
            // pos_blk_off[1][2],
            0
            // pos_blk_off[adv_base_v][adv_blk_v]
        );

        // $display("base_woff: %b, %b", base_woff[0], base_woff[1]);
        // $display("ixq_out_dw [%d, %d]", ixq_out_dw[0], ixq_out_dw[1]);
        // $display("ixq_out_fmsk [%b, %b]", ixq_out_fmsk[0], ixq_out_fmsk[1]);
        // $display("is_end_flat: %b", dut.is_end_flat);
        // $display("align_msk: %b, fmsk: %b", dut.align_msk, dut.fmsk);
        // $display("%d %d %d %d %d",
        //     dut.nal_off_n[0][0],
        //     dut.nal_off_n[0][1],
        //     dut.nal_off_n[0][2],
        //     dut.nal_off_n[0][3],
        //     dut.nal_off_n[0][4]
        // );

        // $display("%b %b %b %b",
        //     dut.nal_is_end[0][0],
        //     dut.nal_is_end[0][1],
        //     dut.nal_is_end[0][2],
        //     dut.nal_is_end[0][3]
        // );
        // $display("off: %d %d", ftq_in_dat[0].off, ftq_in_dat[1].off);
        // $display("fmsk[0]: [%b]", dut.fmsk[0]);
        // $display("dws [%d, %d]", dut.dws[0][0], dut.dws[0][1]);
        // $display("o_dws [%d, %d]", dut.o_dws[0], dut.o_dws[1]);

    endtask

endmodule
