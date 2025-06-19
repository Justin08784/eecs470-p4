`include "sys_defs.svh"

`ifdef  PC_GEN_TEST_MODE
`ifndef PC_GEN_SVA_SVH
`define PC_GEN_SVA_SVH

// `define PC_GEN_SYNTH_MODE
// `ifndef PC_GEN_SYNTH_MODE
// `define PC_GEN_TEST_MODE
// `endif


typedef struct packed {
    DWADDR      dw;     // cache line to which it belongs
    logic       is_end; // is end of fb?

    WADDR       base;   // fb base
    logic[3:0]  off;    // in-fb offset

    // logic       ft;     // was fb predicted fallthrough?
    // logic       fmsk;   // fetchable?
    // FTQ_ENTRY   fb;     // fb to which it belongs
} WORD_STREAM_PKT;

function automatic WORD_STREAM_PKT [15:0] fb2stream (
    input FTQ_ENTRY     fb,
    input WADDR         base,   // of fetch block
    input logic [3:0]   off,    // starting offset in fb
    output int          num     // of packets produced
);
    WORD_STREAM_PKT [15:0] rv;
    WADDR   cur_pc;
    DWADDR  cur_dw;
    logic   is_end;
    logic[3:0] cur_off;
    int     w;

    // assert (reset || off <= fb.off) else $fatal;

    rv = '0;

    num = 0;
    for (w = 0; w < 16; ++w) begin
        cur_off = off + w;
        cur_pc  = base + cur_off;
        cur_dw  = cur_pc[13:1];
        is_end  = cur_off == fb.off;

        rv[num] = '{
            dw      : cur_dw,
            is_end  : is_end,
            base    : base,
            off     : cur_off
        };

        ++num;

        if (is_end)
            break;
    end

    return rv;
endfunction


function automatic WORD_STREAM_PKT [1:0] ixq_out2stream (
    input DWADDR            dw,
    input logic [1:0][3:0]  off,
    input logic [1:0]       fmsk,
    input logic [1:0]       is_end,

    output int  num     // of packets produced
);
    WORD_STREAM_PKT [1:0] rv;
    WADDR   line_start, cur_pc;
    int     w;

    line_start = dw << 1;

    rv = '0;

    num = 0;
    for (w = 0; w < 2; ++w) begin
        cur_pc  = line_start + w;
        if (!fmsk[w])
            continue;

        rv[num] = '{
            dw      : dw,
            is_end  : is_end[w],
            base    : cur_pc - off[w],
            off     : off[w]
        };

        ++num;
    end

    return rv;
endfunction


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
    input   FB_OFF[1:0][1:0]ixq_out_off,
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

        if (merge_l0) begin
            fmsk[1][0]  |= fmsk[0][0];
            is_end[1][0]|= is_end[0][0];
        end

        if (merge_l1) begin
            fmsk[1][0]  |= fmsk[0][1];
            is_end[1][0]|= is_end[0][1];
        end

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

        /*TODO:
        Edge case to test. Output block 0 is a merger of 00 and 10, but buf
        has room for only 1. Suppose that we output exacty 1 block. This means:
        - we still push the merged 00 + 10 block but...
        - we write only ftq0 to buf, which means ftq1 should be marked as !inbuf
        in cur.inbuf
        */
        

    endfunction

    int     ftq_id_next, buf_id_next;
    // logic   ftq_ids[int];
    logic   buf_ids[int]; // TODO: update
    WORD_STREAM_PKT in_stream   [$];

    WORD_STREAM_PKT [NUM_W*NUM_DW-1:0] out_stream;
    int wr_idx;

    struct packed {
        WADDR base;
        logic [3:0] off;
    } cur, cur_n;

    initial begin
        ftq_id_next = 0;
        buf_id_next = 0;
    forever begin
        step(
            sva_seq_n,
            sva_seq,
            sva_comb_n
        );

        $display("step: %b %b", sva_seq_n, reset);
        $display("stpc: %b %b", sva_comb_n, reset);
        print_comb(sva_comb_n);

        for (int e = 0; e < ftq_in_vld_scnt; ++e) begin
            FTQ_ENTRY fb;
            WORD_STREAM_PKT [15:0] in_append;
            int num_append;

            fb = ftq_in_dat[e];
            if (fb.id < ftq_id_next) // already added
                continue;

            in_append = fb2stream(fb, cur_n.base, cur_n.off, num_append);
            for (int w = 0; w < num_append; ++w)
                in_stream.push_back(in_append[w]);

            // assert(!ftq_ids.exists(cur_id));
            // ftq_ids[cur_id] = 1;

            cur_n.base = fb.base_n;
            cur_n.off  = 0;

            ++ftq_id_next;
        end


        wr_idx = 0;
        for (int e = 0; e < ixq_out_wen_cnt; ++e) begin
            WORD_STREAM_PKT [1:0] in_append;
            int num_append;

            in_append = ixq_out2stream(
                ixq_out_dw[e],
                ixq_out_off[e],
                ixq_out_fmsk[e],
                ixq_out_is_end[e],
                num_append
            );

            for (int w = 0; w < num_append; ++w) begin
                out_stream[wr_idx] = in_append[w];
                ++wr_idx;
            end
        end


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
            cur     <= '{
                base: reset_val.base,
                off : reset_val.off
            };

        end else begin
            sva_comb<= sva_comb_n;
            sva_seq <= sva_seq_n;
            dut_comb<= dut_comb_n;
            dut_seq <= dut_seq_n;
            diff    <= diff_n;

            if (flush)
                cur <= '{
                    base: flush_fb_base,
                    off : flush_pc_off
                };
            else
                cur <= cur_n;

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
        $display("diff seq: off: %b, base: %b, inbuf: %b",
            diff.off,
            diff.base,
            diff.inbuf
        );

        $display("diff ftq: ren_cnt: %b",
            diff.ftq_out_ren_cnt
        );

        $display("diff ixq: wen_cnt: %b, dw: %b, fmsk: %b, is_end: %b",
            diff.ixq_out_wen_cnt,
            diff.ixq_out_dw,
            diff.ixq_out_fmsk,
            diff.ixq_out_is_end
        );

        $display("diff buf: wen_cnt: %b, dat: %b",
            diff.buf_out_wen_cnt,
            diff.buf_out_dat
        );
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
`endif // PC_GEN_TEST_MODE