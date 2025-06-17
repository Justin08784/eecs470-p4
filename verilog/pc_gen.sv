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
    input   `CNT_TYPE(2)    ixq_in_rdy_scnt, // = `MIN(iqq_*, irq_*)
    output  `CNT_TYPE(2)    ixq_out_wen_cnt,
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

    FB_OFF  [NUM_FTQ:0][NUM_DW:0] pos_blk_off;
    generate
    assign pos_blk_off[2] = '0;
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign pos_blk_off[e][0] = '0;

        for (genvar b = 1; b <= NUM_DW; ++b) begin
            assign pos_blk_off[e][b] = off_n[e][W_PER_DW*b];
        end
    end
    endgenerate

    WADDR [NUM_FTQ:0] base_n;
    assign base_n[0] = cur.base;
    assign base_n[1] = ftq_in_dat[0].base_n;
    assign base_n[2] = ftq_in_dat[1].base_n;

    logic   [NUM_DW:0][`CNT_SIZE(NUM_FTQ)-1:0]  adv_base;
    logic   [NUM_DW:0][`CNT_SIZE(NUM_DW)-1:0]   adv_blk;

    DWADDR  [NUM_DW-1:0]    o_dws;
    logic   [NUM_DW-1:0][W_PER_DW-1:0]  o_fmsk;
    logic   [NUM_DW-1:0][W_PER_DW-1:0]  o_is_end;

    logic ftq1_vld;
    assign ftq1_vld = ftq_in_vld_scnt[1];

    logic merge_l0, merge_l1;
    assign merge_l0 = ftq1_vld
        && !is_end[0][0][W_PER_DW-1]
        && ftq_in_dat[0].ft;
    assign merge_l1 = ftq1_vld
        && !is_end[0][1][W_PER_DW-1]
        && ftq_in_dat[0].ft;

    logic bhe00;
    logic bhe01;
    logic bhe10;
    logic bhe11;
    logic any_bh1;

    assign bhe00    = blk_has_end[0][0];
    assign bhe01    = blk_has_end[0][1];
    assign bhe10    = blk_has_end[1][0];
    assign bhe11    = blk_has_end[1][1];
    assign any_bh1  = bhe10 | bhe11;

    assign adv_base [0] = 0;
    assign adv_blk  [0] = 0;

    // ------------------------------------------------------------------
    // adv_*[1]
    // ------------------------------------------------------------------
    always_comb begin
        unique case (1'b1)
            bhe00 &  merge_l0 &  bhe10: begin
                adv_base[1] = 2;
                adv_blk [1] = 0;
            end
            bhe00 &  merge_l0 & ~bhe10: begin
                adv_base[1] = 1;
                adv_blk [1] = 1;
            end
            bhe00 & ~merge_l0: begin
                adv_base[1] = 1;
                adv_blk [1] = 0;
            end

            bhe01: begin
                adv_base[1] = 0;
                adv_blk [1] = 1;
            end

            default: begin
                adv_base[1] = 0;
                adv_blk [1] = 1;
            end
        endcase
    end

    // ------------------------------------------------------------------
    // adv_*[2]
    // ------------------------------------------------------------------
    always_comb begin
        unique case (1'b1)
            bhe00 &  merge_l0 & any_bh1: begin
                adv_base[2] = 2;
                adv_blk [2] = 0;
            end
            bhe00 &  merge_l0 & ~any_bh1: begin
                adv_base[2] = 1;
                adv_blk [2] = 2;
            end
            bhe00 & ~merge_l0 &  bhe10: begin
                adv_base[2] = 2;
                adv_blk [2] = 0;
            end
            bhe00 & ~merge_l0 & ~bhe10: begin
                adv_base[2] = 1;
                adv_blk [2] = 1;
            end

            (~bhe00 & bhe01) & merge_l1 &  bhe10: begin
                adv_base[2] = 2;
                adv_blk [2] = 0;
            end
            (~bhe00 & bhe01) & merge_l1 & ~bhe10: begin
                adv_base[2] = 1;
                adv_blk [2] = 1;
            end
            (~bhe00 & bhe01) & ~merge_l1: begin
                adv_base[2] = 1;
                adv_blk [2] = 0;
            end

            default: begin
                adv_base[2] = 0;
                adv_blk [2] = 2;
            end
        endcase
    end


    // ------------------------------------------------------------------
    // o_*[0]
    // ------------------------------------------------------------------
    always_comb begin
        o_dws[0] = dws[0][0];

        unique case (1'b1)
            bhe00 &  merge_l0: begin
                o_fmsk  [0] = fmsk  [0][1]  |   fmsk  [1][0];
                o_is_end[0] = is_end[0][1]  |   is_end[1][0];
            end

            default: begin
                o_fmsk  [0] = fmsk  [0][0];
                o_is_end[0] = is_end[0][0];
            end
        endcase
    end

    // ------------------------------------------------------------------
    // o_*[1]
    // ------------------------------------------------------------------
    always_comb begin
        unique case (1'b1)
            bhe00 &  merge_l0: begin
                o_dws   [1] = dws   [1][1];
                o_fmsk  [1] = fmsk  [1][1];
                o_is_end[1] = is_end[1][1];
            end
            bhe00 & ~merge_l0: begin
                o_dws   [1] = dws   [1][0];
                o_fmsk  [1] = fmsk  [1][0];
                o_is_end[1] = is_end[1][0];
            end

            bhe01 &  merge_l1: begin
                o_dws   [1] = dws   [0][1];
                o_fmsk  [1] = fmsk  [0][1]  |   fmsk  [1][0];
                o_is_end[1] = is_end[0][1]  |   is_end[1][0];
            end
            bhe01 & ~merge_l1: begin
                o_dws   [1] = dws   [0][1];
                o_fmsk  [1] = fmsk  [0][1];
                o_is_end[1] = is_end[0][1];
            end

            default: begin
                o_dws   [1] = dws   [0][1];
                o_fmsk  [1] = fmsk  [0][1];
                o_is_end[1] = is_end[0][1];
            end
        endcase
    end


    `CNT_TYPE(NUM_FTQ) buf_lim_cnt;
    logic [NUM_FTQ-1:0] req_buf;
    logic [NUM_FTQ:0][`CNT_SIZE(NUM_FTQ)-1:0] buf_prefix_cnt;
    compactor #(
        .REQW(NUM_FTQ),
        .GNTW(NUM_FTQ)
    ) comp_buf_req (
        .req        (req_buf),
        .lim_cnt    (buf_in_rdy_scnt),
        .prefix_cnt (buf_prefix_cnt),
        .gnt_cnt    (buf_lim_cnt)
    );

    always_comb begin
        `CNT_TYPE(NUM_DW) tmp;
        ixq_out_dw      = o_dws;
        ixq_out_fmsk    = o_fmsk;
        ixq_out_is_end  = o_is_end;

        tmp = `MIN(ftq_in_vld_scnt, ixq_in_rdy_scnt);

        req_buf[0] = !cur.inbuf;
        req_buf[1] = adv_base[tmp] != 0;

        ixq_out_wen_cnt = `MIN(buf_lim_cnt, tmp);

        ftq_out_ren_cnt = adv_base[ixq_out_wen_cnt];

        buf_out_dat = '0;
        for (int i = 0; i < NUM_FTQ; ++i)
            buf_out_dat[buf_prefix_cnt[i]] = ftq_in_dat[i];
        buf_out_wen_cnt = buf_prefix_cnt[ixq_out_wen_cnt];
    end

    // DWADDR [NUM_DW-1:0] flush_dw;
    // FB_OFF [NUM_W-1:0]  flush_off;
    // generate
    // assign flush_off[0] = flush_pc_off;
    // for (genvar w = 1; w < NUM_W; ++w)
    //     assign flush_off[w] = flush_pc_off + `UCAST_FIT(w);

    // WADDR flush_start;
    // assign flush_start = flush_fb_base + flush_pc_off;
    // assign flush_dw[0] = flush_start[13:1];
    // assign flush_dw[1] = flush_start[13:1] + `UCAST_FIT(1);
    // endgenerate

    `CNT_TYPE(NUM_FTQ)  adv_base_v;
    `CNT_TYPE(NUM_DW)   adv_blk_v;
    assign adv_base_v   = adv_base  [ixq_out_wen_cnt];
    assign adv_blk_v    = adv_blk   [ixq_out_wen_cnt];

    always_ff @(posedge clock) begin
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

        else
            cur <= '{
                off  : pos_blk_off[adv_base_v][adv_blk_v],
                base : base_n[adv_base_v],
                inbuf: ixq_out_wen_cnt != 0 && (adv_base_v != 2)
            };

    end

    task print_pc_gen;
        // $display("ftq_in_dat[*].off: [%d, %d]",
        //     ftq_in_dat[0].off,
        //     ftq_in_dat[1].off,
        // );

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

        $display("ixq_out: wen_cnt = %d, dw = [%d, %d], fmsk = %b, is_end = %b",
            ixq_out_wen_cnt,
            ixq_out_dw[0],
            ixq_out_dw[1],
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

        $display("adv_base: [%d, %d, %d] -> %d",
            adv_base[0],
            adv_base[1],
            adv_base[2],
            adv_base_v
        );

        $display("adv_blk: [%d, %d, %d] -> %d",
            adv_blk[0],
            adv_blk[1],
            adv_blk[2],
            adv_blk_v
        );

        $display("pos_blk_off: [\n[%d, %d, %d],\n[%d, %d, %d],\n[%d, %d, %d]] -> %d",
            pos_blk_off[0][0],
            pos_blk_off[0][1],
            pos_blk_off[0][2],
            pos_blk_off[1][0],
            pos_blk_off[1][1],
            pos_blk_off[1][2],
            pos_blk_off[2][0],
            pos_blk_off[2][1],
            pos_blk_off[2][2],
            pos_blk_off[adv_base_v][adv_blk_v]
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
