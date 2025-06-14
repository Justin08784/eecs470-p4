`include "sys_defs.svh"

module pc_gen_test;
    logic clock;
    logic reset;
    logic flush;
    BMASK clmsk;

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
    logic[1:0][1:0] irq_out_fmsk;
    logic[1:0][1:0] irq_out_is_end;
    // FTQ buffer
    `CNT_TYPE(2)    buf_in_rdy_scnt;
    `CNT_TYPE(2)    buf_out_wen_cnt;
    FTQ_ENTRY[1:0]  buf_out_dat;

    task automatic wr_ftq0(
        WADDR   base_n,
        logic   ft,
        logic [3:0] off
    );
        ftq_in_dat[0] = '0;
        ftq_in_dat[0].base_n    = base_n;
        ftq_in_dat[0].ft        = ft;
        ftq_in_dat[0].off       = off;
    endtask

    task automatic wr_ftq1(
        WADDR   base_n,
        logic   ft,
        logic [3:0] off
    );
        ftq_in_dat[1] = '0;
        ftq_in_dat[1].base_n    = base_n;
        ftq_in_dat[1].ft        = ft;
        ftq_in_dat[1].off       = off;
    endtask

    pc_gen dut (
        .clock,
        .reset,
        .flush,
        .clmsk,

        .ftq_in_vld_scnt,
        .ftq_in_dat,
        .ftq_out_ren_cnt,

        .ixq_in_rdy_scnt,
        .ixq_out_wen_cnt,
        .ixq_out_dw,
        .irq_out_fmsk,
        .irq_out_is_end,

        .buf_in_rdy_scnt,
        .buf_out_wen_cnt,
        .buf_out_dat
    );

    initial begin
        $display("\nStart Testbench");
        clock = 0;
        reset = 1;

        ftq_in_vld_scnt = 0;
        ftq_in_dat      = 0;


        // $monitor("  %3d | d_in: [%d, %d]   wr_en_cnt: %d  rd_en_cnt: %d  |  d_out: [%d, %d]   used_scnt: %2d  free_scnt: %2d",
        //     $time,
        //     wr_en_cnt > 0 ? wr_data[0] : 0,
        //     wr_en_cnt > 1 ? wr_data[1] : 0,
        //     wr_en_cnt,
        //     rd_en_cnt,
        //     rd_data[0], 
        //     rd_data[1], 
        //     used_scnt, 
        //     free_scnt);

        @(negedge clock);
        reset = 0;
        @(negedge clock);

        ftq_in_vld_scnt = 1;
        wr_ftq0(0, 0, 15);
        wr_ftq1(0, 0, 0);
        #0;

        $display("ixq_out_dw [%d, %d]", ixq_out_dw[0], ixq_out_dw[1]);
        $display("irq_out_fmsk [%b, %b]", irq_out_fmsk[0], irq_out_fmsk[1]);
        $display("word_is_end: %b", dut.word_is_end);
        $display("align_msk: %b, fmsk: %b", dut.align_msk, dut.fmsk);
        $display("fmsk[0]: [%b]", dut.fmsk[0]);
        $display("dws [%d, %d]", dut.dws[0][0], dut.dws[0][1]);
        $display("dws_out [%d, %d]", dut.dws_out[0], dut.dws_out[1]);
        $display("blk_status [%d, %d]", dut.blk_status[0][0], dut.blk_status[0][1]);

        $finish;
    end

endmodule