`include "sys_defs.svh"

`ifndef PC_GEN_SVA_SVH
`define PC_GEN_SVA_SVH

// `define PC_GEN_SYNTH_MODE
`ifndef PC_GEN_SYNTH_MODE
`define PC_GEN_TEST_MODE
`endif

module pc_gen_sva #(
    parameter MAX_W_PER_FB  =16,
    parameter W_PER_DW      =2,
    parameter NUM_DW        =2,
    parameter NUM_FTQ       =2,
    localparam NUM_W = NUM_DW*W_PER_DW,
    type FB_OFF = `IDX_TYPE(MAX_W_PER_FB)
) (
    input   logic [3:0] off,
    input   WADDR       base,
    input   logic       inbuf,

    input   clock,
    input   reset,
    input   flush,

    input   WADDR           flush_fb_base,
    input   logic [3:0]     flush_pc_off,
    input   struct packed {
        logic [3:0] off;
        WADDR       base;
        logic       inbuf;
    } reset_val,

    // ftq
    input   `CNT_TYPE(2)    ftq_in_vld_scnt,
    input   FTQ_ENTRY[1:0]  ftq_in_dat,
    input   `CNT_TYPE(2)    ftq_out_ren_cnt,

    // irq / iqq
    // **NOTE**: ixq_out_off is not checked
    input   `CNT_TYPE(2)    ixq_in_rdy_scnt, // = `MIN(iqq_*, irq_*)
    input   `CNT_TYPE(2)    ixq_out_wen_cnt,
    input   DWADDR [1:0]    ixq_out_dw,
    input   logic[1:0][1:0] ixq_out_fmsk,
    input   logic[1:0][1:0] ixq_out_is_end,

    // FTQ buffer
    input   `CNT_TYPE(2)    buf_in_rdy_scnt,
    input   `CNT_TYPE(2)    buf_out_wen_cnt,
    input   FTQ_ENTRY[1:0]  buf_out_dat
);
    typedef struct packed {
        FB_OFF  off;
        WADDR   base;
        logic   inbuf; // FTQ entry allocated in buf?
    } SEQ_LINES;

    typedef struct packed {
        `CNT_TYPE(2)    ftq_out_ren_cnt;
        // irq / iqq
        `CNT_TYPE(2)    ixq_out_wen_cnt;
        DWADDR[1:0]     ixq_out_dw;
        logic[1:0][1:0] ixq_out_fmsk;
        logic[1:0][1:0] ixq_out_is_end;
        // FTQ buffer
        `CNT_TYPE(2)    buf_out_wen_cnt;
        FTQ_ENTRY[1:0]  buf_out_dat;
    } COMB_LINES;

    COMB_LINES  sva_comb, sva_comb_n,
                dut_comb, dut_comb_n,
                sva_comb_cmp, dut_comb_cmp, cmp_msk;
    SEQ_LINES   sva_seq, sva_seq_n,
                dut_seq, dut_seq_n;

    assign dut_comb_n   = '{
        ftq_out_ren_cnt :ftq_out_ren_cnt,
        
        ixq_out_wen_cnt :ixq_out_wen_cnt,
        ixq_out_dw      :ixq_out_dw,
        ixq_out_fmsk    :ixq_out_fmsk,
        ixq_out_is_end  :ixq_out_is_end,
        
        buf_out_wen_cnt :buf_out_wen_cnt,
        buf_out_dat     :buf_out_dat
    };
    assign dut_seq_n    = '{
        off     : off,
        base    : base,
        inbuf   : inbuf
    };

    struct packed {
        logic   off;
        logic   base;
        logic   inbuf;

        logic   ftq_out_ren_cnt;
        logic   ixq_out_wen_cnt,
                ixq_out_dw,
                ixq_out_fmsk,
                ixq_out_is_end;
        logic   buf_out_wen_cnt,
                buf_out_dat;
    } diff, diff_n;

    always_comb begin
        cmp_msk = '1;
        for (int w = 0; w < NUM_DW; ++w) begin
            if (w < ixq_out_wen_cnt)
                continue;

            cmp_msk.ixq_out_dw[w]      = '0;
            cmp_msk.ixq_out_fmsk[w]    = '0;
            cmp_msk.ixq_out_is_end[w]  = '0;
        end

        for (int f = 0; f < NUM_FTQ; ++f) begin
            if (f < buf_out_wen_cnt)
                continue;
            cmp_msk.buf_out_dat[f] = '0;
        end

        sva_comb_cmp = sva_comb_n & cmp_msk;
        dut_comb_cmp = dut_comb_n & cmp_msk;

        diff_n = '{
            off             : sva_seq.off   != off,
            base            : sva_seq.base  != base,
            inbuf           : sva_seq.inbuf != inbuf,

            ftq_out_ren_cnt : sva_comb_cmp.ftq_out_ren_cnt  != ftq_out_ren_cnt,
        
            ixq_out_wen_cnt : sva_comb_cmp.ixq_out_wen_cnt  != dut_comb_cmp.ixq_out_wen_cnt,
            ixq_out_dw      : sva_comb_cmp.ixq_out_dw       != dut_comb_cmp.ixq_out_dw,
            ixq_out_fmsk    : sva_comb_cmp.ixq_out_fmsk     != dut_comb_cmp.ixq_out_fmsk,
            ixq_out_is_end  : sva_comb_cmp.ixq_out_is_end   != dut_comb_cmp.ixq_out_is_end,

            buf_out_wen_cnt : sva_comb_cmp.buf_out_wen_cnt  != dut_comb_cmp.buf_out_wen_cnt,
            buf_out_dat     : sva_comb_cmp.buf_out_dat      != dut_comb_cmp.buf_out_dat
        };

    end

    function automatic void step(
        output  SEQ_LINES   n,  // next state
        input   SEQ_LINES   s,  // current state
        output  COMB_LINES  c
    );
        WADDR   tmp_waddr;
        WADDR   [NUM_FTQ:0] base_n;
        logic   [NUM_FTQ-1:0] base_woff;
        FB_OFF  [NUM_FTQ-1:0][NUM_W-1:0] nal_off_n;
        DWADDR  [NUM_FTQ-1:0][NUM_DW-1:0] dws;
        logic   [NUM_FTQ-1:0][NUM_DW-1:0] blk_has_end;
        logic   [NUM_FTQ-1:0][NUM_W-1:0] is_end_flat, fmsk_flat;
        logic   [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] is_end, fmsk;
        int     blk_num_fetch [NUM_FTQ-1:0][NUM_DW-1:0];

        int avail, cur_off;
        logic [1:0][`CNT_SIZE(NUM_FTQ)-1:0] aft_bidx;
        FB_OFF [1:0] aft_off;

        // >> vld_scnt == 2 case only:
        logic [NUM_DW-1:0] req_buf;
        logic merge_l0, merge_l1;

        // ftq0 line statuses
        typedef enum logic [1:0] {
            LS_CON,             // line continues (no end)
            LS_END_NOMER,       // line ends. no LB0 merge needed
            LS_END_MERGE,       // line ends, and requires LB0 merge. LB0 does not end
            LS_END_MERGE_END    // line ends, and requires LB0 merge, and LB0 ends
        } LINE_STATUS;

        logic [NUM_FTQ*NUM_DW-1:0] pos_ftq;
        logic [NUM_FTQ*NUM_DW-1:0] pos_blk;

        LINE_STATUS l0_status, l1_status;
        // <<

        n = s;
        c = '0;
        if (reset) // the ff block handles resets
            return;

        if (flush) begin
            n = '{
                off     : flush_pc_off,
                base    : flush_fb_base,
                inbuf   : 0
            };
            return;
        end

        tmp_waddr = s.base + s.off;
        dws[0][0] = tmp_waddr[13:1];
        dws[0][1] = dws[0][0] + 1;
        dws[1][0] = ftq_in_dat[0].base_n[13:1];
        dws[1][1] = dws[1][0] + 1;

        base_woff[0] = tmp_waddr[0];
        base_woff[1] = ftq_in_dat[0].base_n[0];

        base_n[0] = s.base;
        base_n[1] = ftq_in_dat[0].base_n;
        base_n[2] = ftq_in_dat[1].base_n;

        nal_off_n[0][0] = s.off;
        nal_off_n[1][0] = 0;
        for (int w = 1; w < NUM_W; ++w) begin
            nal_off_n[0][w] = nal_off_n[0][0] + w;
            nal_off_n[1][w] = nal_off_n[1][0] + w;
        end

        is_end_flat = '0;
        fmsk_flat   = '0;
        for (int e = 0; e < NUM_FTQ; ++e) begin
            for (int w = 0; w < NUM_W; ++w) begin
                int i;
                i = base_woff[e] + w;
                is_end_flat[e][i] = nal_off_n[e][w] == ftq_in_dat[e].off;
            end
        end

        for (int e = 0; e < NUM_FTQ; ++e) begin
            for (int w = 0; w < NUM_W; ++w) begin
                int i;
                i = base_woff[e] + w;
                fmsk_flat[e][i] = 1;

                if (is_end_flat[e][i])
                    break;
            end
        end

        for (int e = 0; e < NUM_FTQ; ++e) begin
            for (int b = 0; b < NUM_DW; ++b) begin
                fmsk         [e][b] = fmsk_flat[e][W_PER_DW*b +: W_PER_DW];
                is_end       [e][b] = is_end_flat[e][W_PER_DW*b +: W_PER_DW];
                blk_has_end  [e][b] = |is_end[e][b];
                blk_num_fetch[e][b] = $countones(fmsk[e][b]);
            end
        end

        avail = 0;
        merge_l0 = (ftq_in_vld_scnt >= 2)
            && blk_has_end[0][0]
            && !is_end[0][0][W_PER_DW-1]
            && ftq_in_dat[0].ft;
        merge_l1 = (ftq_in_vld_scnt >= 2)
            && blk_has_end[0][1]
            && !is_end[0][1][W_PER_DW-1]
            && ftq_in_dat[0].ft;

        cur_off = s.off;
        aft_bidx = '0;
        pos_ftq = '0;
        pos_blk = '0;
        aft_off = '0;

        // ftq 0
        for (int b = 0; b < NUM_DW; ++b) begin
            if (ftq_in_vld_scnt < 1)
                break;
            
            if (blk_has_end[0][b]) begin
                logic merge;

                merge = b ? merge_l1 : merge_l0;

                if (merge) begin
                    aft_bidx[avail]= 1;
                    pos_ftq[avail] = 1;
                    pos_blk[avail] = 0;
                    aft_off[avail] = 0;

                    cur_off = 0;

                end else begin
                    aft_bidx[avail]= 0;
                    pos_ftq[avail] = 0;
                    pos_blk[avail] = b;
                    aft_off[avail] = cur_off + blk_num_fetch[0][b];

                    cur_off = 0;
                    ++avail;
                end
                break;
            end

            cur_off += blk_num_fetch[0][b];

            aft_bidx[avail]= 0;
            pos_ftq[avail] = 0;
            pos_blk[avail] = b;
            aft_off[avail] = cur_off;
            ++avail;
        end

        // ftq 1
        for (int b = 0; b < NUM_DW; ++b) begin
            if (ftq_in_vld_scnt < 2)
                break;
            if (avail == NUM_DW) // full
                break;

            if (blk_has_end[1][b]) begin
                aft_bidx[avail]= 2;
                pos_ftq[avail] = 1;
                pos_blk[avail] = b;
                aft_off[avail] = 0;

                break;
            end

            cur_off += blk_num_fetch[1][b];

            aft_bidx[avail]= 1;
            pos_ftq[avail] = 1;
            pos_blk[avail] = b;
            aft_off[avail] = cur_off;
            ++avail;
        end

        req_buf[0] = (!s.inbuf || aft_bidx[0] > 0);
        req_buf[1] = aft_bidx[1] > 0;

        for (int i = 0; i < avail; ++i) begin
            int e, b;
            e = pos_ftq[i];
            b = pos_blk[i];

            c.ixq_out_dw[i]     = dws[e][b];
            c.ixq_out_fmsk[i]   = fmsk[e][b];
            c.ixq_out_is_end[i] = is_end[e][b];
        end

        c.buf_out_dat[0] = !s.inbuf ? ftq_in_dat[0] : ftq_in_dat[1];
        c.buf_out_dat[1] = ftq_in_dat[1];

        c.ftq_out_ren_cnt = 0;
        c.ixq_out_wen_cnt = 0;
        c.buf_out_wen_cnt = 0;
        for (int i = 0; i < avail; ++i) begin
            if ((i+1 > ixq_in_rdy_scnt)
            ||  (c.buf_out_wen_cnt + req_buf[i] > buf_in_rdy_scnt))
                break;

            n.base  = base_n[aft_bidx[i]];
            n.off   = aft_off[i];
            n.inbuf = aft_bidx[i] != 2;
                // we cant store 3rd FTQ entry (it is not yet in window)

            c.ftq_out_ren_cnt = aft_bidx[i];
            c.ixq_out_wen_cnt = i+1;
            c.buf_out_wen_cnt += req_buf[i];
        end

        return;

        if (ftq_in_vld_scnt == 0)
            return;

        if (ftq_in_vld_scnt == 1) begin
            logic sat; // satisfied

            c.ixq_out_dw[0]     = dws[0][0];
            c.ixq_out_fmsk[0]   = fmsk[0][0];
            c.ixq_out_is_end[0] = is_end[0][0];
            c.buf_out_dat[0]    = ftq_in_dat[0];

            if (s.inbuf) begin
                sat = (ixq_in_rdy_scnt > 0);
                c.buf_out_wen_cnt = 0;
            end else begin
                sat = (ixq_in_rdy_scnt > 0) && (buf_in_rdy_scnt > 0);
                c.buf_out_wen_cnt = sat;
            end
            c.ixq_out_wen_cnt = sat;

            if (c.ixq_out_wen_cnt == 0) begin
                c.ftq_out_ren_cnt = 0;
            end else begin
                logic bhe;

                bhe = blk_has_end[0][0];
                c.ftq_out_ren_cnt = sat && bhe;

                n.off   = bhe ? 0 : s.off + blk_num_fetch[0][0];
                n.base  = ftq_in_dat[0].base_n;
                assert(s.inbuf);
            end

            return;
        end

        assert(ftq_in_vld_scnt == 2);
        merge_l0 = blk_has_end[0][0] && !is_end[0][0][W_PER_DW-1] && ftq_in_dat[0].ft;
        merge_l1 = blk_has_end[0][1] && !is_end[0][1][W_PER_DW-1] && ftq_in_dat[0].ft;

        // // Note: ftq0 needs a buf slot iff !inbuf. ftq1 always needs a buf slot
        // req_buf[0] = !s.inbuf;
        // req_buf[1] = 1;
        c.buf_out_dat[0] = !s.inbuf ? ftq_in_dat[0] : ftq_in_dat[1];
        c.buf_out_dat[1] = ftq_in_dat[1];

        l0_status =
            !blk_has_end[0][0]  ? LS_CON        :
            !merge_l0           ? LS_END_NOMER  :
            !blk_has_end[1][0]  ? LS_END_MERGE  :
            LS_END_MERGE_END;
        l1_status =
            !blk_has_end[0][1]  ? LS_CON        :
            !merge_l1           ? LS_END_NOMER  :
            !blk_has_end[1][0]  ? LS_END_MERGE  :
            LS_END_MERGE_END;

        if (merge_l0) begin
            fmsk[0][0]  |= fmsk[1][0];
            is_end[0][0]|= is_end[1][0];
        end
        if (merge_l1) begin
            fmsk[0][1]  |= fmsk[1][0];
            is_end[0][1]|= is_end[1][0];
        end

        pos_ftq[0] = 0;
        pos_blk[0] = 0;

        unique case (l0_status)
        LS_CON: begin
            pos_ftq[1] = 0;
            pos_blk[1] = 0;

            unique case (l1_status)
            LS_CON: begin
                pos_ftq[2] = 0;
                pos_blk[2] = 1;
            end

            LS_END_NOMER: begin
                pos_ftq[2] = 0;
                pos_blk[2] = 1;
            end

            LS_END_MERGE: begin
                pos_ftq[2] = 1;
                pos_blk[2] = 0;
            end

            LS_END_MERGE_END: begin
                pos_ftq[2] = 1;
                pos_blk[2] = 1;
            end
            endcase
        end

        LS_END_NOMER: begin
            pos_ftq[1] = 0;
            pos_blk[1] = 0;

            pos_ftq[2] = 1;
            pos_blk[2] = 0;
        end

        LS_END_MERGE,
        LS_END_MERGE_END: begin
            pos_ftq[1] = 1;
            pos_blk[1] = 0;

            pos_ftq[2] = 1;
            pos_blk[2] = 1;
        end
        endcase

        // adv_base_v = pos_ftq[1] + blk_has_end[1][1];

        for (int i = 0; i < NUM_DW; ++i) begin
            int e, b;
            e = pos_ftq[i+1];
            b = pos_blk[i+1];

            c.ixq_out_dw[i]     = dws[e][b];
            c.ixq_out_fmsk[i]   = fmsk[e][b];
            c.ixq_out_is_end[i] = is_end[e][b];
        end

        // c.ixq_out_wen_cnt = 0;
        // c.buf_out_wen_cnt = 0;
        // for (int i = 0; i < 2; ++i) begin
        //     if ((i >= ixq_in_rdy_scnt)
        //     ||  (c.buf_out_wen_cnt + req_buf[i] > buf_in_rdy_scnt))
        //         break;

        //     c.ixq_out_wen_cnt = i+1;
        //     c.buf_out_wen_cnt += req_buf[i];
        // end

        /*TODO:
        Edge case to test. Output block 0 is a merger of 00 and 10, but buf
        has room for only 1. Suppose that we output exacty 1 block. This means:
        - we still push the merged 00 + 10 block but...
        - we write only ftq0 to buf, which means ftq1 should be marked as !inbuf
        in cur.inbuf
        */
        

    endfunction

    initial begin
    forever begin
        step(
            sva_seq_n,
            sva_seq,
            sva_comb_n
        );

        $display("step: %b %b", sva_seq_n, reset);
        $display("stpc: %b %b", sva_comb_n, reset);
        print_comb(sva_comb_n);

        @(posedge clock);
        @(negedge clock);
    end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            sva_comb<= '0;
            sva_seq <= reset_val;
            dut_comb<= '0;
            dut_seq <= reset_val;
            diff    <= '0;

        end else begin
            sva_comb<= sva_comb_n;
            sva_seq <= sva_seq_n;
            dut_comb<= dut_comb_n;
            dut_seq <= dut_seq_n;
            diff    <= diff_n;

        end
    end

    task print_seq(input SEQ_LINES s);
        $display("state: off: %h, base: %h, inbuf: %h",
            s.off,
            s.base,
            s.inbuf
        );
    endtask

    task print_comb(input COMB_LINES c);
        $display("ftq_out: ren_cnt: %d",
            c.ftq_out_ren_cnt
        );

        $display("ixq_out: wen_cnt = %d, dw = [%d, %d], fmsk = %b, is_end = %b",
            c.ixq_out_wen_cnt,
            c.ixq_out_dw[0],
            c.ixq_out_dw[1],
            c.ixq_out_fmsk,
            c.ixq_out_is_end,
        );

        $display("buf_out: wen_cnt = %d, [{base_n: %d, ft: %b, off: %d}, {base_n: %d, ft: %b, off: %d}]\n",
            c.buf_out_wen_cnt,
            c.buf_out_dat[0].base_n,
            c.buf_out_dat[0].ft,
            c.buf_out_dat[0].off,
            c.buf_out_dat[1].base_n,
            c.buf_out_dat[1].ft,
            c.buf_out_dat[1].off
        );
    endtask


    task debug;
        $display("exp");
        print_seq(sva_seq);
        print_comb(sva_comb);

        $display("got");
        print_seq(dut_seq);
        print_comb(dut_comb);
        $display("diff: %b", diff);
    endtask

    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            debug;
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        property match_state;
            disable iff (reset)
            diff_n == '0;
        endproperty
    endclocking

    Match_State: assert property(cb.match_state)
        else exit_on_error;

endmodule
`endif // PC_GEN_SVA_SVH