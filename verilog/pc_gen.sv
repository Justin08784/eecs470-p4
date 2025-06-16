`include "sys_defs.svh"

// `define PC_GEN_TEST_MODE

module pc_gen (
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
    typedef enum logic [1:0] {
        END_NONE    =2'b00,
        END_ALI_FT  =2'b01,
        END_NAL_FT  =2'b10,
        END_BRANCH  =2'b11
    } LINE_STATUS;

    localparam MAX_W_PER_FB = 16;// maximum span of a fetch block / ftq entry, in words
    localparam W_PER_DW     = 2; // num words per double-word / cache line
    localparam NUM_DW       = 2; // num double words we can process per cycle
    localparam NUM_FTQ      = 2; // num FTQ entries we can process per cycle
    localparam NUM_W        = NUM_DW*W_PER_DW;

    typedef `IDX_TYPE(MAX_W_PER_FB) FB_OFF;

    function automatic FB_OFF [2*NUM_W:0] init_off_rst();
        FB_OFF [2*NUM_W:0] rv;
        for (int i = 0; i <= NUM_W; ++i)
            rv[i] = i;
        return rv;
    endfunction
    localparam FB_OFF [2*NUM_W-1:0] off_rst = init_off_rst();
    localparam WADDR base_rst = '0;
    localparam logic inbuf_rst = 0;
    localparam DWADDR [NUM_DW-1:0] dw_rst = {DWADDR'(1), DWADDR'(0)};

    struct packed {
        DWADDR  [NUM_DW-1:0] dw;
        FB_OFF  [NUM_W-1:0] off;
        WADDR   base;
        logic   inbuf; // FTQ entry allocated in buf?
    } cur;

    // Form indices: fb offsets, PCs, block DWs
    logic   [NUM_FTQ-1:0] base_woff;            // index: (ftq).
    FB_OFF  [NUM_FTQ-1:0][NUM_W-1:0]nal_off_n;  // index: (ftq, word).
    logic   [NUM_FTQ-1:0][NUM_W-1:0]nal_is_end; // index: (ftq, word). nal = not cache line aligned
    generate
    assign base_woff[0] = cur.base[0] ^ cur.off[0]; // 1 bit add
    assign base_woff[1] = ftq_in_dat[0].base_n[0];

    for (genvar w = 0; w < NUM_W; ++w) begin
        assign nal_off_n[0][w] = cur.off[w];
        assign nal_off_n[1][w] = off_rst[w];
    end

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar w = 0; w < NUM_W; ++w) begin
            assign nal_is_end[e][w] = ftq_in_dat[e].off == nal_off_n[e][w];
        end
    end
    endgenerate


    FB_OFF  [NUM_FTQ-1:0][NUM_W-1:0]off_n;
    logic   [NUM_FTQ-1:0][NUM_W-1:0]is_end_flat, fmsk_flat;
    logic   [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] is_end, fmsk;
    generate
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign off_n[e][0] = base_woff[e]
            ? '0
            : nal_off_n[e][0];

        for (genvar w = 1; w < NUM_W; ++w) begin
            assign off_n[e][w] = base_woff[e]
                ? nal_off_n[e][w-1]
                : nal_off_n[e][w];
        end
    end

    logic   [NUM_FTQ-1:0][NUM_W-1:0] align_msk;
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign align_msk[e]     = {NUM_W{1'b1}} << base_woff[e];
        assign is_end_flat[e]   = nal_is_end[e] << base_woff[e];
    end

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign fmsk_flat[e][0] = align_msk[e][0];

        for (genvar w = 1; w < NUM_W; ++w) begin
            assign fmsk_flat[e][w] =
                fmsk_flat[e][w-1] && align_msk[e][w] && !is_end_flat[e][w-1];
        end
    end

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar b = 0; b < NUM_DW; ++b) begin
            assign fmsk  [e][b] = fmsk_flat  [e][W_PER_DW*b +: W_PER_DW];
            assign is_end[e][b] = is_end_flat[e][W_PER_DW*b +: W_PER_DW];
        end
    end
    endgenerate


    logic       [NUM_FTQ-1:0][NUM_DW-1:0] blk_has_end;
    LINE_STATUS [NUM_FTQ-1:0][NUM_DW-1:0] blk_status;
    generate
    logic   [NUM_FTQ-1:0] ft;
    for (genvar e = 0; e < NUM_FTQ; ++e)
        assign ft[e] = ftq_in_dat[e].ft;

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar b = 0; b < NUM_DW; ++b) begin
            assign blk_has_end[e][b]= |is_end[e][b];
            assign blk_status [e][b]=
                !blk_has_end[e][b]              ? END_NONE      :
                !ft[e]                          ? END_BRANCH    :
                is_end_flat[e][W_PER_DW*(b+1)-1]? END_ALI_FT    : END_NAL_FT;
        end
    end
    endgenerate


    DWADDR  [NUM_FTQ:0][NUM_DW-1:0] dws;
    DWADDR  [NUM_FTQ:0][NUM_DW-1:0] dws_nex;
    DWADDR  [NUM_FTQ:0][2*NUM_DW-1:0] dws_full;
    generate
    assign dws[0] = cur.dw;

    assign dws[1][0] = ftq_in_dat[0].base_n[13:1];
    assign dws[2][0] = ftq_in_dat[1].base_n[13:1];
    for (genvar b = 1; b < NUM_DW; ++b) begin
        assign dws[1][b] = dws[1][0] + `UCAST_FIT(b);
        assign dws[2][b] = dws[2][0] + `UCAST_FIT(b);
    end

    for (genvar b = 0; b < NUM_DW; ++b) begin
        assign dws_nex[0][b] = dws[0][NUM_DW-1] + `UCAST_FIT(b+1);
        assign dws_nex[1][b] = dws[1][0]        + `UCAST_FIT(NUM_DW+b);
        assign dws_nex[2][b] = '0;
    end

    assign dws_full[0] = {dws_nex[0], dws[0]};
    assign dws_full[1] = {dws_nex[1], dws[1]};
    assign dws_full[2] = {dws_nex[2], dws[2]};
    endgenerate

    FB_OFF  [NUM_FTQ:0][2*NUM_W-1:0]  off_full;
    FB_OFF  [NUM_W-1:0] off_nex0;
    logic   [NUM_FTQ:0][NUM_DW:0][`CNT_SIZE(NUM_W)-1:0] pos_blk_inc; // TODO: UNSURE
    generate
    for (genvar w = 0; w < NUM_W; ++w)
        assign off_nex0[w] = cur.off[NUM_W-1] + `UCAST_FIT(w+1);
    assign off_full[0] = {off_nex0, nal_off_n[0]};
    assign off_full[1] = off_rst;
    assign off_full[2] = off_rst;

    assign pos_blk_inc[2] = '0;
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign pos_blk_inc[e][0] = '0;
        for (genvar b = 1; b <= NUM_DW; ++b) begin
            assign pos_blk_inc[e][b] = base_woff[e]
                ? off_rst[W_PER_DW*(b-1)+1]
                : off_rst[W_PER_DW*(b-1)];
        end
    end
    endgenerate

    WADDR [NUM_FTQ:0] base_n;
    assign base_n[0] = cur.base;
    assign base_n[1] = ftq_in_dat[0].base_n;
    assign base_n[2] = ftq_in_dat[1].base_n;

    logic   merge_l0,
            merge_l1;
    logic   [NUM_DW:0][`CNT_SIZE(NUM_FTQ)-1:0]  adv_base;
    logic   [NUM_DW:0][`CNT_SIZE(NUM_DW)-1:0]   adv_blk;

    DWADDR  [NUM_DW-1:0]    o_dws;
    logic   [NUM_DW-1:0][W_PER_DW-1:0]  o_fmsk;
    logic   [NUM_DW-1:0][W_PER_DW-1:0]  o_is_end;
    always_comb begin
        logic ftq1_vld;
        ftq1_vld = ftq_in_vld_scnt[1];
        // ftq1_vld = ftq_in_vld_scnt >= `UCAST_FIT(2);

        o_dws   = '0;
        o_fmsk  = '0;
        o_is_end= '0;

        adv_base    = '0;
        adv_blk     = '0;

        adv_base[0] = 0;
        adv_blk [0] = 0;
        o_dws   [0] = dws   [0][0];
        o_fmsk  [0] = fmsk  [0][0];
        o_is_end[0] = is_end[0][0];

        unique case (blk_status[0][0])
        END_NONE: begin
            o_dws   [1] = dws   [0][1];
            o_fmsk  [1] = fmsk  [0][1];
            o_is_end[1] = is_end[0][1];

            adv_base[1] = 0;
            adv_blk [1] = 1;
            unique case (blk_status[0][1])
            END_NONE: begin
                adv_base[2] = 0;
                adv_blk [2] = 2;
            end

            END_ALI_FT,
            END_BRANCH: begin
                adv_base[2] = 1;
                adv_blk [2] = 0;
            end

            END_NAL_FT: begin
                adv_base[2] = blk_has_end[1][0] ? 2 : 1;
                adv_blk [2] = blk_has_end[1][0] ? 0 : 1;
            end
            endcase
        end

        END_ALI_FT,
        END_BRANCH: begin
            o_dws   [1] = dws   [1][0];
            o_fmsk  [1] = fmsk  [1][0];
            o_is_end[1] = is_end[1][0];

            adv_base[1] = 1;
            adv_blk [1] = 0;

            adv_base[2] = blk_has_end[1][0] ? 2 : 1;
            adv_blk [2] = blk_has_end[1][0] ? 0 : 1;
        end

        END_NAL_FT: begin
            o_dws   [1] = dws   [1][1];
            o_fmsk  [1] = fmsk  [1][1];
            o_is_end[1] = is_end[1][1];

            if (ftq1_vld) begin
                adv_base[1] = blk_has_end[1][0] ? 2 : 1;
                adv_blk [1] = blk_has_end[1][0] ? 0 : 1;
            end else begin
                adv_base[1] = 1;
                adv_blk [1] = 0;
            end

            adv_base[2] = |blk_has_end[1]   ? 2 : 1;
            adv_blk [2] = |blk_has_end[1]   ? 0 : 2;
        end
        endcase

        merge_l0 = ftq1_vld
            && (blk_status[0][0] == END_NAL_FT);
        merge_l1 = ftq1_vld
            && (blk_status[0][0] == END_NONE)
            && (blk_status[0][1] == END_NAL_FT);

        if (merge_l0) begin
            o_fmsk  [0] |= fmsk  [1][0];
            o_is_end[0] |= is_end[1][0];
        end

        if (merge_l1) begin
            o_fmsk  [1] |= fmsk  [1][0];
            o_is_end[1] |= is_end[1][0];
        end
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

    DWADDR [NUM_DW-1:0] flush_dw;
    FB_OFF [NUM_W-1:0] flush_off;
    generate
    assign flush_off[0] = flush_pc_off;
    for (genvar w = 1; w < NUM_W; ++w)
        assign flush_off[w] = flush_pc_off + `UCAST_FIT(w);

    WADDR flush_start;
    assign flush_start = flush_fb_base + flush_pc_off;
    assign flush_dw[0] = flush_start[13:1];
    assign flush_dw[1] = flush_start[13:1] + `UCAST_FIT(1);
    endgenerate

    always_ff @(posedge clock) begin
        if (reset)
`ifndef PC_GEN_TEST_MODE
            cur <= '{
                dw  : dw_rst,
                off : off_rst,
                base: base_rst,
                inbuf:inbuf_rst
            };
`else
            cur <= reset_val;
`endif
        else if (flush)
            cur <= '{
                dw   : flush_dw,
                inbuf: 0,
                base : flush_fb_base,
                off  : flush_off
            };
        else begin
            `CNT_TYPE(NUM_FTQ)  adv_base_v;
            `CNT_TYPE(NUM_DW)   adv_blk_v;
            `CNT_TYPE(NUM_W)    adv_wrd_v;

            adv_base_v  = adv_base   [ixq_out_wen_cnt];
            adv_blk_v   = adv_blk    [ixq_out_wen_cnt];
            adv_wrd_v   = pos_blk_inc[adv_base_v][adv_blk_v];

            cur <= '{
                dw   : dws_full[base_n[adv_base_v]][adv_blk_v +: NUM_DW+1],
                // inbuf: ixq_out_wen_cnt != 0, // FIXME: probably wrong. inbuf shuld be zeroed if adv_base is 2
                inbuf: ixq_out_wen_cnt != 0 && (adv_base_v != 2),
                base : base_n[adv_base_v],
                // off  : off_full[base_n[adv_base_v]][adv_wrd_v +: NUM_W+1]
                off  : off_full[base_n[adv_base_v]][adv_wrd_v +: NUM_W+1]
            };
        end
    end

endmodule
