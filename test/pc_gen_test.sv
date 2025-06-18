`include "sys_defs.svh"
`include "test/pc_gen_sva.svh"

module pc_gen_test;
    localparam MAX_W_PER_FB = 16;// maximum span of a fetch block / ftq entry, in words
    localparam W_PER_DW     = 2; // num words per double-word / cache line
    localparam NUM_DW       = 2; // num double words we can process per cycle
    localparam NUM_FTQ      = 2; // num FTQ entries we can process per cycle
    localparam NUM_W        = NUM_DW*W_PER_DW;

    typedef `IDX_TYPE(MAX_W_PER_FB) FB_OFF;

    logic   clock;
    logic   reset;
    logic   flush;
    WADDR   flush_fb_base;
    FB_OFF  flush_pc_off;

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

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

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
    struct packed {
        FB_OFF  off;
        WADDR   base;
        logic   inbuf; // FTQ entry allocated in buf?
    } s_rst;

    pc_gen #(
        .MAX_W_PER_FB   (MAX_W_PER_FB),
        .W_PER_DW       (W_PER_DW),
        .NUM_DW         (NUM_DW),
        .NUM_FTQ        (NUM_FTQ)
    ) dut (
        .clock,
        .reset,
        .flush,
        .flush_fb_base,
        .flush_pc_off,

`ifdef PC_GEN_TEST_MODE
        .reset_val      ('{
            off     : s_rst.off,
            base    : s_rst.base,
            inbuf   : s_rst.inbuf
        }),
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


`ifdef PC_GEN_TEST_MODE
    pc_gen_sva #(
        .MAX_W_PER_FB   (MAX_W_PER_FB),
        .W_PER_DW       (W_PER_DW),
        .NUM_DW         (NUM_DW),
        .NUM_FTQ        (NUM_FTQ)
    ) sva (
        .off    (dut.cur.off),
        .base   (dut.cur.base),
        .inbuf  (dut.cur.inbuf),

        .clock,
        .reset,
        .flush,
        .flush_fb_base,
        .flush_pc_off,

        .reset_val      ('{
            off     : s_rst.off,
            base    : s_rst.base,
            inbuf   : s_rst.inbuf
        }),

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
`endif


`ifndef PC_GEN_TEST_MODE
    initial begin
        $fatal("\n\033[31mPC_GEN_TEST_MODE (in pc_gen.sv) must be defined!\033[0m\n");
    end
`else
    initial begin
        f0 = '0;
        f1 = '0;
        f0.slot[1:0]= 10'h42;
        f1.slot[1:0]= 10'h100;
        tmp_f0 = '0;
        tmp_f1 = '0;

        $display("\nStart Testbench");
        clock = 0;
        flush = 0;
        flush_fb_base   = '0;
        flush_pc_off    = '0;


        $display("Test 1:");
        reset = 1;
        s_rst = '{
            off     : 3,
            base    : 14,
            inbuf   : 0
        };

        @(negedge clock);
        reset = 0;

        // WADDR       base_n,
        // logic       ft,
        // logic [3:0] off

        ixq_in_rdy_scnt = 2;
        buf_in_rdy_scnt = 2;
        ftq_in_vld_scnt = 2;
        // tmp_f0 = wr_ftq(f0, 0, 0, 4);
        tmp_f0 = wr_ftq(f0, 19, 1, 4);
        tmp_f1 = wr_ftq(f1, 0, 0, 15);
        ftq_in_dat = {tmp_f1, tmp_f0};

        // sva_comb = '{
        //     ftq_out_ren_cnt : 0,
        //     ixq_out_wen_cnt : 2,
        //     ixq_out_dw      : {DWADDR'(9), DWADDR'(8)},
        //     ixq_out_fmsk    : {2'b11, 2'b10},
        //     ixq_out_is_end  : {2'b00, 2'b00},
        //     buf_out_wen_cnt : 1,
        //     buf_out_dat     : {tmp_f1, tmp_f0}
        // };

        // n = '{
        //     off     : 6,
        //     base    : 14,
        //     inbuf   : 1
        // };

        #0; dut.print_pc_gen; // 0 delay ensures all combinational signals have settled before printing
        @(posedge clock);


        // $display("Test 1:");
        // reset = 1;
        // s_rst = '0;
        // @(negedge clock);
        // // code
        // @(posedge clock);

        @(negedge clock);


        $finish;
    end
`endif

endmodule