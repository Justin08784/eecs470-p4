`include "sys_defs.svh"

module pc_gen_test;
    logic clock;
    logic reset;
    logic flush;

    localparam MAX_W_PER_FB = 16;// maximum span of a fetch block / ftq entry, in words
    localparam W_PER_DW     = 2; // num words per double-word / cache line
    localparam NUM_DW       = 2; // num double words we can process per cycle
    localparam NUM_FTQ      = 2; // num FTQ entries we can process per cycle
    localparam NUM_W        = NUM_DW*W_PER_DW;

    typedef `IDX_TYPE(MAX_W_PER_FB) FB_OFF;

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    `CNT_TYPE(2)    ftq_in_vld_scnt;
    FTQ_ENTRY[1:0]  ftq_in_dat;
    `CNT_TYPE(2)    ftq_out_ren_cnt;
    // irq / iqq
    `CNT_TYPE(2)    ixq_in_rdy_scnt;
    `CNT_TYPE(2)    ixq_out_wen_cnt;
    DWADDR[1:0]     ixq_out_dw;
    logic[1:0][1:0] ixq_out_fmsk;
    logic[1:0][1:0] ixq_out_is_end;
    // FTQ buffer
    `CNT_TYPE(2)    buf_in_rdy_scnt;
    `CNT_TYPE(2)    buf_out_wen_cnt;
    FTQ_ENTRY[1:0]  buf_out_dat;

    function automatic FTQ_ENTRY wr_ftq(
        FTQ_ENTRY   f,
        WADDR       base_n,
        logic       ft,
        logic [3:0] off
    );
        FTQ_ENTRY rv;
        rv          = f;
        rv.base_n   = base_n;
        rv.ft       = ft;
        rv.off      = off;
        return rv;
    endfunction

    FTQ_ENTRY f0, f1, tmp_f0, tmp_f1;

    typedef struct packed {
        FB_OFF  off;
        WADDR   base;
        logic   inbuf; // FTQ entry allocated in buf?
    } SEQ_LINES;
    SEQ_LINES s, n, s_rst;


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
    COMB_LINES sva_comb, dut_comb;

    struct packed {
        logic   state;
        logic   ftq_out_ren_cnt;
        logic   ixq_out_wen_cnt,
                ixq_out_dw,
                ixq_out_fmsk,
                ixq_out_is_end;
        logic   buf_out_wen_cnt,
                buf_out_dat;
    } diff, diff_n;

    assign diff_n = '{
        state           : s != dut.cur,
        ftq_out_ren_cnt : sva_comb.ftq_out_ren_cnt  != ftq_out_ren_cnt,
    
        ixq_out_wen_cnt : sva_comb.ixq_out_wen_cnt  != ixq_out_wen_cnt,
        ixq_out_dw      : sva_comb.ixq_out_dw       != ixq_out_dw,
        ixq_out_fmsk    : sva_comb.ixq_out_fmsk     != ixq_out_fmsk,
        ixq_out_is_end  : sva_comb.ixq_out_is_end   != ixq_out_is_end,

        buf_out_wen_cnt : sva_comb.buf_out_wen_cnt  != buf_out_wen_cnt,
        buf_out_dat     : sva_comb.buf_out_dat      != buf_out_dat
    };

    pc_gen dut (
        .clock,
        .reset,
        .flush,
        .flush_fb_base  ('0),
        .flush_pc_off   ('0),

`ifdef PC_GEN_TEST_MODE
        .reset_val      (s_rst),
`endif

        .ftq_in_vld_scnt,
        .ftq_in_dat,
        .ftq_out_ren_cnt,

        .ixq_in_rdy_scnt,
        .ixq_out_wen_cnt,
        .ixq_out_dw,
        .ixq_out_fmsk,
        .ixq_out_is_end,

        .buf_in_rdy_scnt,
        .buf_out_wen_cnt,
        .buf_out_dat
    );

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
        print_seq(s);
        print_comb(sva_comb);

        $display("got");
        print_seq(dut.cur);
        print_comb(dut_comb);
        $display("diff: %b", diff);
    endtask


    always_ff @(posedge clock) begin
        if (reset) begin
            s       <= s_rst;
            dut_comb<= '0;
            diff    <= '0;
        end else begin
            s       <= n;
            dut_comb<= '{
                ftq_out_ren_cnt :ftq_out_ren_cnt,
                
                ixq_out_wen_cnt :ixq_out_wen_cnt,
                ixq_out_dw      :ixq_out_dw,
                ixq_out_fmsk    :ixq_out_fmsk,
                ixq_out_is_end  :ixq_out_is_end,
                
                buf_out_wen_cnt :buf_out_wen_cnt,
                buf_out_dat     :buf_out_dat
            };
            diff    <= diff_n;
        end
    end

`ifndef PC_GEN_TEST_MODE
    initial begin
        $fatal("\n\033[31mPC_GEN_TEST_MODE (in pc_gen.sv) must be defined!\033[0m\n");
    end
`else
    initial begin
        assert ()
        n  = '0;
        f0 = '0;
        f1 = '0;

        f0.slot[1:0]= 10'h42;
        f1.slot[1:0]= 10'h100;

        tmp_f0 = '0;
        tmp_f1 = '0;

        $display("\nStart Testbench");
        clock = 0;
        reset = 1;
        flush = 0;
        s_rst = '{
            off     : 3,
            base    : 14,
            inbuf   : 0
        };

        @(negedge clock);
        reset = 0;

        ixq_in_rdy_scnt = 2;
        buf_in_rdy_scnt = 2;
        ftq_in_vld_scnt = 2;
        tmp_f0 = wr_ftq(f0, 0, 0, 15);
        tmp_f1 = wr_ftq(f1, 0, 0, 0);
        ftq_in_dat = {tmp_f1, tmp_f0};

        sva_comb = '{
            ftq_out_ren_cnt : 0,
            ixq_out_wen_cnt : 2,
            ixq_out_dw      : {DWADDR'(9), DWADDR'(8)},
            ixq_out_fmsk    : {2'b11, 2'b10},
            ixq_out_is_end  : {2'b00, 2'b00},
            buf_out_wen_cnt : 1,
            buf_out_dat     : {tmp_f1, tmp_f0}
        };

        n = '{
            off     : 6,
            base    : 14,
            inbuf   : 1
        };

        #0; dut.print_pc_gen; // 0 delay ensures all combinational signals have settled before printing

        @(posedge clock);

        // reset = 1;
        @(negedge clock);
        // reset = 0;
        // @(negedge clock);
        // debug;


        $finish;

        $display("base_woff: %b, %b", dut.base_woff[0], dut.base_woff[1]);
        $display("ixq_out_dw [%d, %d]", ixq_out_dw[0], ixq_out_dw[1]);
        $display("ixq_out_fmsk [%b, %b]", ixq_out_fmsk[0], ixq_out_fmsk[1]);
        $display("is_end_flat: %b", dut.is_end_flat);
        $display("align_msk: %b, fmsk: %b", dut.align_msk, dut.fmsk);
        $display("%d %d %d %d %d",
            dut.nal_off_n[0][0],
            dut.nal_off_n[0][1],
            dut.nal_off_n[0][2],
            dut.nal_off_n[0][3],
            dut.nal_off_n[0][4]
        );

        $display("%b %b %b %b",
            dut.nal_is_end[0][0],
            dut.nal_is_end[0][1],
            dut.nal_is_end[0][2],
            dut.nal_is_end[0][3]
        );
        $display("off: %d %d", ftq_in_dat[0].off, ftq_in_dat[1].off);
        $display("fmsk[0]: [%b]", dut.fmsk[0]);
        $display("dws [%d, %d]", dut.dws[0][0], dut.dws[0][1]);
        $display("o_dws [%d, %d]", dut.o_dws[0], dut.o_dws[1]);
        // $display("blk_status [%d, %d]", dut.blk_status[0][0], dut.blk_status[0][1]);
    end
`endif



    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            // $display("%b, %b", n.hist, hist);
            // $display("%2d, %2d", f_rdy_scnt, sva_comb.f_rdy_scnt);
            // $display("%b, %b] %b, %b]", f_ghr[0],f_ghr[1],
            // sva_comb.f_ghr[0], sva_comb.f_ghr[1]);
            // $display("used %d free %d us %d fs %d reset: %b", used, free, used_scnt, free_scnt, reset);
            debug;
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        property match_seq;
            disable iff (reset)
            dut.cur == s;
        endproperty

        property match_ftq_out;
            disable iff (reset)
            sva_comb.ftq_out_ren_cnt == ftq_out_ren_cnt;
        endproperty

        property match_ixq_out;
            disable iff (reset)

            sva_comb.ixq_out_wen_cnt == ixq_out_wen_cnt
                && sva_comb.ixq_out_dw == ixq_out_dw 
                && sva_comb.ixq_out_fmsk == ixq_out_fmsk 
                && sva_comb.ixq_out_is_end == ixq_out_is_end;
        endproperty

        property match_buf_out;
            disable iff (reset)

            sva_comb.buf_out_wen_cnt == buf_out_wen_cnt
                && sva_comb.buf_out_dat == buf_out_dat;
        endproperty
    endclocking

    Match_Seq: assert property(cb.match_seq)
        else exit_on_error;

    Match_Ftq_Out: assert property(cb.match_ftq_out)
        else exit_on_error;
    Match_Ixq_Out: assert property(cb.match_ixq_out)
        else exit_on_error;
    Match_Buf_Out: assert property(cb.match_buf_out)
        else exit_on_error;
endmodule