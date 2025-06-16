`include "sys_defs.svh"

// `define PC_GEN_TEST_MODE

module pc_gen (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,
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

    struct packed {
        logic [4:0][3:0] off;
        WADDR       base;
        logic       inbuf; // FTQ entry allocated in buf?
    } cur;

    // Form indices: fb offsets, PCs, block DWs
    logic   [1:0] base_woff;            // index: (ftq).
    logic   [1:0][4:0][3:0] nal_off_n;  // index: (ftq, word).
    logic   [1:0][3:0] nal_is_end;      // index: (ftq, word). nal = not cache line aligned
    generate
    assign base_woff[0] = cur.base[0] ^ cur.off[0]; // 1 bit add
    assign base_woff[1] = ftq_in_dat[0].base_n[0];

    for (genvar w = 0; w <= 4; ++w) begin
        assign nal_off_n[0][w] = cur.off[w];
        assign nal_off_n[1][w] = w;
    end

    for (genvar w = 0; w < 4; ++w) begin
        assign nal_is_end[0][w] = ftq_in_dat[0].off == nal_off_n[0][w];
        assign nal_is_end[1][w] = ftq_in_dat[1].off == nal_off_n[1][w];
    end
    endgenerate


    logic   [1:0][4:0][3:0] off_n;
    logic   [1:0][3:0]      is_end_flat, fmsk_flat;
    logic   [1:0][1:0][1:0] is_end, fmsk;
    generate
    for (genvar e = 0; e < 2; ++e) begin
        assign off_n[e][0] = base_woff[e]
            ? '0
            : nal_off_n[e][0];

        for (genvar w = 1; w <= 4; ++w) begin
            assign off_n[e][w] = base_woff[e]
                ? nal_off_n[e][w-1]
                : nal_off_n[e][w];
        end
    end


    logic   [1:0][3:0] align_msk;
    for (genvar e = 0; e < 2; ++e) begin
        assign align_msk[e]     = 4'b1111 << base_woff[e];
        assign is_end_flat[e]   = nal_is_end[e] << base_woff[e];
    end

    for (genvar e = 0; e < 2; ++e) begin
        assign fmsk_flat[e][0] = align_msk[e][0];

        for (genvar w = 1; w < 4; ++w) begin
            assign fmsk_flat[e][w] =
                fmsk_flat[e][w-1] && align_msk[e][w] && !is_end_flat[e][w-1];
        end
    end

    for (genvar e = 0; e < 2; ++e) begin
        for (genvar b = 0; b < 2; ++b) begin
            assign fmsk  [e][b] = fmsk_flat  [e][2*b+1:2*b];
            assign is_end[e][b] = is_end_flat[e][2*b+1:2*b];
        end
    end
    endgenerate


    logic       [1:0][1:0] blk_has_end;
    LINE_STATUS [1:0][1:0] blk_status;
    generate
    logic   [1:0] ft;
    for (genvar e = 0; e < 2; ++e)
        assign ft[e] = ftq_in_dat[e].ft;

    for (genvar e = 0; e < 2; ++e) begin
        for (genvar b = 0; b < 2; ++b) begin
            assign blk_has_end[e][b]= |is_end[e][b];
            assign blk_status [e][b]=
                !blk_has_end[e][b]          ? END_NONE      :
                !ft[e]                      ? END_BRANCH    :
                is_end_flat[e][2*(b+1)-1]   ? END_ALI_FT    : END_NAL_FT;
        end
    end
    endgenerate


    DWADDR  [1:0][1:0] dws;
    generate
    WADDR [1:0] start_pc;
    assign start_pc[0] = cur.base + nal_off_n[0][0];
    assign start_pc[1] = ftq_in_dat[0].base_n;

    assign dws[0][0] = start_pc[0][13:1];
    assign dws[0][1] = start_pc[0] + `UCAST_FIT(1);
    assign dws[1][0] = start_pc[1][13:1];
    assign dws[1][1] = start_pc[1] + `UCAST_FIT(1);
    endgenerate


    logic   [2:0][8:0][3:0] off_full;
    logic   [1:0][3:0][3:0] off_nex;
    logic   [1:0][1:0][2:0] pos_blk_inc; // 3rd [2:0] is a `CNT_TYPE(4)
    generate
    for (genvar w = 0; w < 4; ++w) begin
        assign off_nex[0][w] = cur.off[4] + `UCAST_FIT(w+1);
        assign off_nex[1][w] = 4+(w+1);
    end
    assign off_full[0] = {off_nex[0], off_n[0]};
    assign off_full[1] = {off_nex[1], off_n[1]};
    assign off_full[2] = off_full[1];

    for (genvar e = 0; e < 2; ++e) begin
        for (genvar b = 0; b < 2; ++b) begin
            assign pos_blk_inc[e][b] = base_woff[e]
                ? off_full[1][2*b+1]
                : off_full[1][2*b];
        end
    end
    endgenerate

    WADDR [2:0] base_n;
    assign base_n[0] = cur.base;
    assign base_n[1] = ftq_in_dat[0].base_n;
    assign base_n[2] = ftq_in_dat[1].base_n;

    logic   merge_l0,
            merge_l1;
    logic   [2:0][`CNT_SIZE(2)-1:0] adv_base;
    logic   [2:0][`CNT_SIZE(2)-1:0] adv_inc;

    DWADDR  [1:0]       o_dws;
    logic   [1:0][1:0]  o_fmsk;
    logic   [1:0][1:0]  o_is_end;
    always_comb begin
        logic ftq1_vld;
        ftq1_vld = ftq_in_vld_scnt[1];
        // ftq1_vld = ftq_in_vld_scnt >= `UCAST_FIT(2);

        o_dws   = '0;
        o_fmsk  = '0;
        o_is_end= '0;

        adv_base[0] = 0;
        adv_inc [0] = 0;
        o_dws   [0] = dws   [0][0];
        o_fmsk  [0] = fmsk  [0][0];
        o_is_end[0] = is_end[0][0];

        unique case (blk_status[0][0])
        END_NONE: begin
            o_dws   [1] = dws   [0][1];
            o_fmsk  [1] = fmsk  [0][1];
            o_is_end[1] = is_end[0][1];

            adv_base[1] = 0;
            adv_inc [1] = pos_blk_inc[0][0];
            unique case (blk_status[0][1])
            END_NONE: begin
                adv_base[2] = 0;
                adv_inc [2] = pos_blk_inc[0][1];
            end

            END_ALI_FT,
            END_BRANCH: begin
                adv_base[2] = 1;
                adv_inc [2] = 0;
            end

            END_NAL_FT: begin
                adv_base[2] = blk_has_end[1][0] ? 2 : 1;
                adv_inc [2] = blk_has_end[1][0] ? 0 : pos_blk_inc[1][0];
            end
            endcase
        end

        END_ALI_FT,
        END_BRANCH: begin
            o_dws   [1] = dws   [1][0];
            o_fmsk  [1] = fmsk  [1][0];
            o_is_end[1] = is_end[1][0];

            adv_base[1] = 1;
            adv_inc [1] = 0;

            adv_base[2] = blk_has_end[1][0] ? 2 : 1;
            adv_inc [2] = blk_has_end[1][0] ? 0 : pos_blk_inc[1][0];
        end

        END_NAL_FT: begin
            o_dws   [1] = dws   [1][1];
            o_fmsk  [1] = fmsk  [1][1];
            o_is_end[1] = is_end[1][1];

            if (ftq1_vld) begin
                adv_base[1] = blk_has_end[1][0] ? 2 : 1;
                adv_inc [1] = blk_has_end[1][0] ? 0 : pos_blk_inc[1][0];
            end else begin
                adv_base[1] = 1;
                adv_inc [1] = 0;
            end

            adv_base[2] = |blk_has_end[1]   ? 2 : 1;
            adv_inc [2] = |blk_has_end[1]   ? 0 : pos_blk_inc[1][1];
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

    `CNT_TYPE(2) buf_lim_cnt;
    logic [1:0] req_buf;
    logic [2:0][`CNT_SIZE(2)-1:0] buf_prefix_cnt;
    compactor #(
        .REQW(2),
        .GNTW(2)
    ) comp_buf_req (
        .req        (req_buf),
        .lim_cnt    (buf_in_rdy_scnt),
        .prefix_cnt (buf_prefix_cnt),
        .gnt_cnt    (buf_lim_cnt)
    );

    always_comb begin
        `CNT_TYPE(2) tmp;
        ixq_out_dw      = o_dws;
        ixq_out_fmsk    = o_fmsk;
        ixq_out_is_end  = o_is_end;

        tmp = `MIN(ftq_in_vld_scnt, ixq_in_rdy_scnt);

        req_buf[0] = !cur.inbuf;
        req_buf[1] = adv_base[tmp] != 0;

        ixq_out_wen_cnt = `MIN(buf_lim_cnt, tmp);

        ftq_out_ren_cnt = adv_base[ixq_out_wen_cnt];

        buf_out_dat = '0;
        for (int i = 0; i < 2; ++i)
            buf_out_dat[buf_prefix_cnt[i]] = ftq_in_dat[i];
        buf_out_wen_cnt = buf_prefix_cnt[ixq_out_wen_cnt];
    end


    always_ff @(posedge clock) begin
        if (reset)
`ifndef PC_GEN_TEST_MODE
            cur <= '0; // FIXME: off should be reset to {..., 4'h2, 4'h1, 4'h0}
`else
            cur <= reset_val;
`endif
        else
            cur <= '{
                // inbuf: ixq_out_wen_cnt != 0, // FIXME: probably wrong. inbuf shuld be zeroed if adv_base is 2
                inbuf: ixq_out_wen_cnt != 0 && (adv_base[ixq_out_wen_cnt] != 2),
                base : base_n  [adv_base[ixq_out_wen_cnt]],
                off  : off_full
                    [base_n[adv_base[ixq_out_wen_cnt]]]
                    [adv_inc[ixq_out_wen_cnt] +: 5]
            };
    end

endmodule
