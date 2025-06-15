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
        WADDR       base;
        // logic       in_buf; // FTQ entry allocated in buf?
    } cur, cur_n;

    // Form indices: fb offsets, PCs, block DWs
    logic   [1:0] base_woff;            // index: (blk).
    logic   [1:0][4:0][3:0] nal_off_n;  // index: (blk, word).
    logic   [1:0][3:0] nal_is_end; // index: (blk, word). nal = not cache line aligned
    generate
    assign base_woff[0] = cur.base[0] ^ cur.off[0]; // 1 bit add
    assign base_woff[1] = ftq_in_dat[0].base_n[0];

    assign nal_off_n[0][0] = cur.off;
    assign nal_off_n[1][0] = 0;
    for (genvar w = 1; w <= 4; ++w) begin
        assign nal_off_n[0][w] = cur.off + `UCAST_FIT(w);
        assign nal_off_n[1][w] = w;
    end

    for (genvar w = 0; w < 4; ++w) begin
        assign nal_is_end[0][w] = ftq_in_dat[0].off == nal_off_n[0][w];
        assign nal_is_end[1][w] = ftq_in_dat[1].off == w;
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


    DWADDR  [1:0] base_n;
    logic   [1:0][1:0][3:0] pos_blk_off;
    generate
    for (genvar e = 0; e < 2; ++e) begin
        assign base_n[e] = ftq_in_dat[e].base_n;
        for (genvar b = 0; b < 2; ++b)
            assign pos_blk_off[e][b] = off_n[e][2*b];
    end
    endgenerate



    `CNT_TYPE(2) ren_cnt;
    always_comb begin
        unique case (blk_status[0][0])
        END_NONE: begin
            unique case (blk_status[0][1])
            END_NONE:   ren_cnt = 0;

            END_ALI_FT,
            END_BRANCH: ren_cnt = 1;

            END_NAL_FT: ren_cnt = blk_has_end[1][0] ? 2 : 1;
            endcase
        end

        END_ALI_FT,
        END_BRANCH: begin
            unique case (blk_status[1][0])
            END_NONE:   ren_cnt = 1;
            default:    ren_cnt = 2;
            endcase
        end

        END_NAL_FT: begin
            unique case (blk_status[1][0])
            END_NONE:   ren_cnt = 1;
            default:    ren_cnt = 2;
            endcase
        end
        endcase
    end


    struct packed {
        logic [1:0] fmsk;
        logic [1:0] is_end;
    } a0_merge, a1_merge;
    always_comb begin
        a0_merge = '{
            fmsk    : fmsk[0][0]    | fmsk[1][0],
            is_end  : is_end[0][0]  | is_end[1][0]
        };

        a1_merge = '{
            fmsk    : fmsk[0][1]    | fmsk[1][0],
            is_end  : is_end[0][1]  | is_end[1][0]
        };

    end


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

        o_dws[0]    = dws[0][0];
        o_fmsk[0]   = fmsk[0][0];
        o_is_end[0] = is_end[0][0];

        cur_n = cur;
        unique case (blk_status[0][0])
        END_NONE: begin
            o_dws[1]    = dws[0][1];
            o_fmsk[1]   = fmsk[0][1]; // assert  == 2'b11
            o_is_end[1] = is_end[0][1]; // assert == 2'b00

            unique case (blk_status[0][1])
            END_NONE: begin
                // o_dws[1]    = dws[0][1];
                // o_fmsk[1]   = fmsk[0][1]; // assert  == 2'b11
                // o_is_end[1] = is_end[0][1]; // assert == 2'b00

                cur_n.off   = pos_blk_off[0][1];
            end

            END_ALI_FT,
            END_BRANCH: begin
                // o_dws[1]    = dws[0][1];
                // o_fmsk[1]   = fmsk[0][1];
                // o_is_end[1] = is_end[0][1];

                cur_n.base  = base_n[0];
                cur_n.off   = 0;
            end

            END_NAL_FT: begin
                // o_dws[1]    = dws[0][1];
                // o_fmsk[1]   = fmsk[0][1];
                // o_is_end[1] = is_end[0][1];

                cur_n.base  = base_n[0];
                cur_n.off   = 0;
                if (ftq1_vld) begin
                    o_fmsk[1]   = a1_merge.fmsk;
                    o_is_end[1] = a1_merge.is_end;

                    if (blk_has_end[1][0])
                        cur_n.base  = base_n[1];
                    else
                        cur_n.off   = pos_blk_off[1][0];

                end
            end
            endcase
        end

        END_ALI_FT,
        END_BRANCH: begin
            o_dws[1]    = dws[1][0];
            o_fmsk[1]   = fmsk[1][0];
            o_is_end[1] = is_end[1][0];

            cur_n.base  = base_n[0];
            cur_n.off   = 0;
            if (ftq1_vld) begin
                if (blk_has_end[1][0])
                    cur_n.base  = base_n[1];
                else
                    cur_n.off   = pos_blk_off[1][0];

            end
        end


        END_NAL_FT: begin
            o_dws[1]    = dws[1][1];
            o_fmsk[1]   = fmsk[1][1];
            o_is_end[1] = is_end[1][1];

            cur_n.base  = base_n[0];
            cur_n.off   = 0;
            if (ftq1_vld) begin
                o_fmsk[0]   = a0_merge.fmsk;
                o_is_end[0] = a0_merge.is_end;


                if (blk_has_end[1][0] || blk_has_end[1][1])
                    cur_n.base  = base_n[1];
                else
                    cur_n.off   = pos_blk_off[1][1];

            end
        end
        endcase
    end

    generate
    assign ixq_out_dw   = o_dws;
    assign irq_out_fmsk = o_fmsk;
    endgenerate


    always_ff @(posedge clock) begin
        if (reset)
            cur <= '0;
        else
            cur <= cur_n;
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
