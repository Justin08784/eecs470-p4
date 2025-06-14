`include "sys_defs.svh"

module pc_gen (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,

    // ftq
    input   `CNT_TYPE(2)    ftq_in_vld_scnt,
    input   FTQ_ENTRY[1:0]  ftq_in_dat,
    output  `CNT_TYPE(2)    ftq_out_ren_cnt,

    // irq / iqq
    input   `CNT_TYPE(2)    ixq_in_rdy_scnt, // = `MIN(iqq_*, irq_*)
    output  `CNT_TYPE(2)    ixq_out_wen_cnt,
    output  DWADDR [1:0]    ixq_out_dw,
    output  logic[1:0][1:0] irq_out_fmsk,
    output  logic[1:0][1:0] irq_out_is_end,

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
        logic [3:0] off;
        WADDR       fb_base;
        // logic       in_buf; // FTQ entry allocated in buf?
    } cur, cur_n;

    // Form indices: fb offsets, PCs, block DWs
    logic   base_woff [1:0];    // index: (blk).
    logic   [4:0][3:0] off_n;   // index: (word). ftq0 offsets
    logic   [1:0][3:0] nal_word_is_end; // index: (blk, word). nal = not cache line aligned
    generate
    assign base_woff[0] = cur.fb_base[0] ^ cur.off[0]; // 1 bit add
    assign base_woff[1] = ftq_in_dat[0].base_n[0];

    assign off_n[0] = cur.off;
    for (genvar i = 1; i <= 4; ++i)
        assign off_n[i] = cur.off + `UCAST_FIT(i);

    for (genvar w = 0; w < 4; ++w)
        assign nal_word_is_end[0][w] = ftq_in_dat[0].off == off_n[w];

    assign nal_word_is_end[1][0] = ftq_in_dat[1].off == 0;
    for (genvar w = 1; w < 4; ++w)
        assign nal_word_is_end[1][w] = ftq_in_dat[1].off == `UCAST_FIT(w);
    endgenerate

    logic   [1:0] ft;
    logic   [1:0][1:0] blk_has_end;
    LINE_STATUS [1:0][1:0] blk_status;
    logic   [1:0][3:0] word_is_end, align_msk, fmsk;
    generate
    for (genvar e = 0; e < 2; ++e) begin
        assign ft[e] = ftq_in_dat[e].ft;
        assign align_msk[e] = 4'b1111 << base_woff[e];
        assign word_is_end[e] = nal_word_is_end[e] << base_woff[e];
    end

    for (genvar e = 0; e < 2; ++e) begin
        for (genvar b = 0; b < 2; ++b) begin
            assign blk_has_end[e][b] = word_is_end[e][2*b] || word_is_end[e][2*b+1];
            assign blk_status[e][b] =
                !blk_has_end[e][b] ? END_NONE :
                !ft[e] ? END_BRANCH :
                word_is_end[e][2*(b+1)-1] ? END_ALI_FT : END_NAL_FT;
        end
    end

    for (genvar e = 0; e < 2; ++e) begin
        assign fmsk[e][0] = align_msk[e][0];
        for (genvar b = 1; b < 2; ++b) begin
            assign fmsk[e][b] = align_msk[e][b] && !word_is_end[e][b-1];
        end
    end
    endgenerate


    DWADDR  [1:0][1:0] dws;
    generate
    WADDR [1:0] start_pc;
    assign start_pc[0] = cur.fb_base + off_n[0];
    assign start_pc[1] = ftq_in_dat[0].base_n;

    assign dws[0][0] = start_pc[0][13:1];
    assign dws[0][1] = start_pc[0] + `UCAST_FIT(1);
    assign dws[1][0] = start_pc[1][13:1];
    assign dws[1][1] = start_pc[1] + `UCAST_FIT(1);
    endgenerate


    DWADDR  [1:0]       dws_out;
    logic   [1:0][1:0]  fmsk_out;
    always_comb begin
        logic ftq1_vld;
        ftq1_vld = `UCAST_FIT(1) >= ftq_in_vld_scnt;

        dws_out = '0;
        fmsk_out= '0;

        dws_out[0]  = dws[0][0];
        fmsk_out[0] = fmsk[0][0];

        cur_n = cur;
        unique case (blk_status[0][0])
        END_NONE: begin
            unique case (blk_status[0][1])
            END_NONE: begin
                dws_out[1]  = dws[0][1];
                fmsk_out[1] = fmsk[0][1]; // assert  == 1'b1111
                // cur_n // TODO
            end

            END_ALI_FT,
            END_BRANCH: begin
                dws_out[1]  = dws[0][1];
                fmsk_out[1] = fmsk[0][1];
                // cur_n // TODO
            end

            END_NAL_FT: begin
                dws_out[1]  = dws[0][1];
                fmsk_out[1] = fmsk[0][1] | (ftq1_vld ? fmsk[1][0] : '0);
                // cur_n // TODO
            end
            endcase
        end

        END_ALI_FT,
        END_BRANCH: begin
            dws_out[1]  = dws[1][0];
            fmsk_out[1] = fmsk[1][0];
            // cur_n // TODO
        end


        END_NAL_FT: begin
            fmsk_out[0] |= ftq1_vld ? fmsk[1][0] : '0;
            dws_out[1]  = dws[1][1];
            fmsk_out[1] = fmsk[1][1];
            // cur_n // TODO
        end
        endcase
    end

    generate
    assign ixq_out_dw   = dws_out;
    assign irq_out_fmsk = fmsk_out;
    endgenerate


    always_ff @(posedge clock) begin
        if (reset)
            cur <= '0;
        else begin
        end
    end

    always_comb begin
        // if ftq0.blk0 has nal-ft-endpoint begin
        //     merge
        // end

    //     /*
    //     FTQ 0 format -> request
    //     0: [jump, - ] -> 0.0, 1.0
    //     0: [ft, jump] -> 0.0, 0.1
    //     0: [ft, jump] -> 0.0, 0.1
    //     */
    //     if (blk_has_end[0][0]) begin
    //     end else if (blk_has_end[0][1]) begin
    //     end
    end

endmodule
