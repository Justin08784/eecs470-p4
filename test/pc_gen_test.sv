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

    task automatic wr_ftq0(
        FTQ_ENTRY f,
        WADDR   base_n,
        logic   ft,
        logic [3:0] off
    );
        ftq_in_dat[0] = f;

        ftq_in_dat[0].base_n    = base_n;
        ftq_in_dat[0].ft        = ft;
        ftq_in_dat[0].off       = off;
    endtask

    task automatic wr_ftq1(
        FTQ_ENTRY f,
        WADDR   base_n,
        logic   ft,
        logic [3:0] off
    );
        ftq_in_dat[1] = f;

        ftq_in_dat[1].base_n    = base_n;
        ftq_in_dat[1].ft        = ft;
        ftq_in_dat[1].off       = off;
    endtask

    pc_gen dut (
        .clock,
        .reset,
        .flush,
        .flush_fb_base  ('0),
        .flush_pc_off   ('0),

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

    FTQ_ENTRY f0, f1;


    // base_n
    // ft
    // off

    struct packed {
        FB_OFF  off;
        WADDR   base;
        logic   inbuf; // FTQ entry allocated in buf?
    } s, n;

    task debug;
        $display("s: off: %h, base: %h, inbuf: %h",
            s.off,
            s.base,
            s.inbuf
        );
        $display("cur: off: %h, base: %h, inbuf: %h",
            dut.cur.off,
            dut.cur.base,
            dut.cur.inbuf
        );

        $display("ftq_in: vld_scnt = %d, [{base_n: %d, ft: %b, off: %d}, {base_n: %d, ft: %b, off: %d}], ftq_out: ren_cnt: %d",
            ftq_in_vld_scnt,
            ftq_in_dat[0].base_n,
            ftq_in_dat[0].ft,
            ftq_in_dat[0].off,
            ftq_in_dat[1].base_n,
            ftq_in_dat[1].ft,
            ftq_in_dat[1].off,
            ftq_out_ren_cnt
        );

        $display("ixq_out: dw = [%d, %d], fmsk = [%b%b, %b%b], is_end = [%b%b, %b%b]",
            ixq_out_dw[0],
            ixq_out_dw[1],
            ixq_out_fmsk[0][0],
            ixq_out_fmsk[0][1],
            ixq_out_fmsk[1][0],
            ixq_out_fmsk[1][1],
            ixq_out_is_end[0][0],
            ixq_out_is_end[0][1],
            ixq_out_is_end[1][0],
            ixq_out_is_end[1][1]
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
    endtask

    struct packed {
        `CNT_TYPE(2)    ftq_out_ren_cnt;
        // irq / iqq
        `CNT_TYPE(2)    ixq_out_wen_cnt;
        DWADDR[1:0]     ixq_out_dw;
        logic[1:0][1:0] ixq_out_fmsk;
        logic[1:0][1:0] ixq_out_is_end;
        // FTQ buffer
        `CNT_TYPE(2)    buf_out_wen_cnt;
        FTQ_ENTRY[1:0]  buf_out_dat;
    } sva_comb;

    always_ff @(posedge clock) begin
        if (reset)
            s <= '0;
        else
            s <= n;
    end

    initial begin
        n  = '0;
        f0 = '0;
        f1 = '0;

        f0.slot[1:0]= 10'h42;
        f1.slot[1:0]= 10'h100;

        $display("\nStart Testbench");
        clock = 0;
        reset = 1;
        flush = 0;

        ftq_in_vld_scnt = 0;
        ftq_in_dat      = '0;

        ixq_in_rdy_scnt = 0;
        buf_in_rdy_scnt = 0;

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

        // base_n
        // ft
        // off

        @(negedge clock);
        reset = 0;
        @(negedge clock);

        ixq_in_rdy_scnt = 2;
        buf_in_rdy_scnt = 2;
        ftq_in_vld_scnt = 2;
        wr_ftq0(f0, 0, 0, 15);
        wr_ftq1(f1, 0, 0, 0);
        // debug;
        #0;

        n = '{
            off : 4,
            base: 0,
            inbuf : 1
        };

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

        // @(posedge clock);
        @(negedge clock);

        // ftq_in_vld_scnt = 2;
        // wr_ftq0(0, 1, 2);
        // wr_ftq1(69, 0, 8);
        // #0;
        debug;


        $finish;
    end



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
    endclocking

    Match_Seq: assert property(cb.match_seq)
        else exit_on_error;
endmodule