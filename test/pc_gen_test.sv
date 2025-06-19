`include "sys_defs.svh"
`include "test/pc_gen_sva.svh"

`ifdef PC_GEN_TEST_MODE
// stimulus engine
module pc_gen_stim #(
    parameter MAX_W_PER_FB  = 16,// maximum span of a fetch block / ftq entry, in words
    parameter W_PER_DW      = 2, // num words per double-word / cache line
    parameter NUM_DW        = 2, // num double words we can process per cycle
    parameter NUM_FTQ       = 2, // num FTQ entries we can process per cycle
    type FB_OFF=`IDX_TYPE(MAX_W_PER_FB),
    localparam  NUM_W       = NUM_DW*W_PER_DW
) (
    input   clock,
    input   reset,
    output  logic flush,

    output  WADDR       flush_fb_base,
    output  logic [3:0] flush_pc_off,
    input   struct packed {
        logic [3:0] off;
        WADDR       base;
        logic       inbuf;
    } reset_val,

    // ftq
    output  `CNT_TYPE(2)    ftq_in_vld_scnt,
    output  FTQ_ENTRY[1:0]  ftq_in_dat,
    input   `CNT_TYPE(2)    ftq_out_ren_cnt,

    // irq / iqq
    output  `CNT_TYPE(2)    ixq_in_rdy_scnt, // = `MIN(iqq_*, irq_*)
    input   `CNT_TYPE(2)    ixq_out_wen_cnt,
    input   FB_OFF[1:0][1:0]ixq_out_off,
    input   DWADDR [1:0]    ixq_out_dw,
    input   logic[1:0][1:0] ixq_out_fmsk,
    input   logic[1:0][1:0] ixq_out_is_end,

    // FTQ buffer
    output  `CNT_TYPE(2)    buf_in_rdy_scnt,
    input   `CNT_TYPE(2)    buf_out_wen_cnt,
    input   FTQ_ENTRY[1:0]  buf_out_dat
);
    localparam _FTQ_SZ = 8;
    localparam _BUF_SZ = 8;

    FTQ_ENTRY _ftq [$], _buf [$];
    logic   ftq_ids[int],
            buf_ids[int];
    // does id exist in X? (doesn't need to have logic type, but SV doesn't support sets... right?)

    int ftq_sz, buf_sz, num_add, num_del;

    int cur_id; // ignores reset/flushes. monotonic identifier
    struct packed {
        WADDR base;
    } cur, cur_n;

    // struct packed {
    // } rand_pkt;

    initial begin
        cur_id = 0;

        // FIXME
        flush   = 0;
        flush_fb_base   = '0;
        flush_pc_off    = '0;

        ftq_in_vld_scnt = 0;
        ftq_in_dat      = '0;
        ixq_in_rdy_scnt = 0;
        buf_in_rdy_scnt = 0;

    // forever begin
    // repeat (1000) begin
    repeat (10) begin

        ftq_sz = _ftq.size();
        buf_sz = _buf.size();

        $display("cur: id: %4d, base: %d", cur_id, cur.base);
        for (int e = 0; e < ftq_sz; ++e)
            $display("ftq[%1d]: off: %d, ft: %b, base_n: %d (id: %0d)",
                e,
                _ftq[e].off,
                _ftq[e].ft,
                _ftq[e].base_n,
                _ftq[e].id
            );
        for (int e = 0; e < buf_sz; ++e)
            $display("buf[%1d]: off: %d, ft: %b, base_n: %d (id: %0d)",
                e,
                _buf[e].off,
                _buf[e].ft,
                _buf[e].base_n,
                _buf[e].id
            );

        ftq_in_vld_scnt = `MIN(ftq_sz, 2); // TODO: randomly restrict this below the true count?
        ftq_in_dat = '0;
        for (int e = 0; e < ftq_in_vld_scnt; ++e)
            ftq_in_dat[e] = _ftq[e];
        ixq_in_rdy_scnt = 2; // TODO: make this random
        buf_in_rdy_scnt = `MIN(_BUF_SZ-buf_sz, 2); // TODO: Likewise. random restriction

        num_add = _FTQ_SZ-ftq_sz;
        cur_n = cur;
        for (int e = 0; e < num_add; ++e) begin
            // localparam MAX_OFF_VAL = 1 << 15 - MAX_W_PER_FB; // FIXME: how to handle?
            FTQ_ENTRY fb;

            std::randomize(fb);

            if (fb.ft)
                fb.base_n = cur_n.base + fb.off + 1;

            fb.id = cur_id;
            _ftq.push_back(fb);

            assert(!ftq_ids.exists(cur_id));
            ftq_ids[cur_id] = 1;

            ++cur_id;
            cur_n.base = fb.base_n;
        end

        // consume some buffer entries
        num_del = `MIN(buf_sz, 2); // TODO: make this random too
        for (int e = 0; e < num_del; ++e) begin
            FTQ_ENTRY fb;
            if (ftq_ids.exists(_buf[e].id))
                break;

            fb = _buf.pop_front();
            buf_ids.delete(fb.id);
        end

        @(posedge clock);
        @(negedge clock);
    end

        $finish;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            _ftq.delete();
            _buf.delete();
            buf_ids.delete();
            ftq_ids.delete();
            cur <= '{
                base: reset_val.base
            };

        end else if (flush) begin
            _ftq.delete();
            _buf.delete();
            buf_ids.delete();
            ftq_ids.delete();
            cur <= '{
                base: flush_fb_base
            };

        end else begin
            cur <= cur_n;

            for (int e = 0; e < ftq_out_ren_cnt; ++e) begin
                FTQ_ENTRY fb;

                fb = _ftq.pop_front();
                ftq_ids.delete(fb.id);
            end

            for (int e = 0; e < buf_out_wen_cnt; ++e) begin
                FTQ_ENTRY fb;
                fb = buf_out_dat[e];

                _buf.push_back(fb);
                buf_ids[fb.id] = 1;
            end
        end

    end
endmodule
`endif

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
    FB_OFF[1:0][1:0]ixq_out_off;
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
        .ixq_out_off,
        .ixq_out_dw,
        .ixq_out_fmsk,
        .ixq_out_is_end,

        .buf_in_rdy_scnt,
        .buf_out_wen_cnt,
        .buf_out_dat
    );


`ifdef PC_GEN_TEST_MODE
    pc_gen_stim #(
        .MAX_W_PER_FB   (MAX_W_PER_FB),
        .W_PER_DW       (W_PER_DW),
        .NUM_DW         (NUM_DW),
        .NUM_FTQ        (NUM_FTQ)
    ) stim (
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
        .ixq_out_off,
        .ixq_out_dw,
        .ixq_out_fmsk,
        .ixq_out_is_end,

        .buf_in_rdy_scnt,
        .buf_out_wen_cnt,
        .buf_out_dat
    );

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
        .ixq_out_off,
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

        $display("Test 1:");
        reset = 1;
        s_rst = '{
            off     : 3,
            base    : 14,
            inbuf   : 0
        };

        @(negedge clock);
        reset = 0;
    // forever begin

        // WADDR       base_n,
        // logic       ft,
        // logic [3:0] off

        // ixq_in_rdy_scnt = 2;
        // buf_in_rdy_scnt = 2;
        // ftq_in_vld_scnt = 2;
        // tmp_f0 = wr_ftq(f0, 19, 1, 4);
        // tmp_f1 = wr_ftq(f1, 0, 0, 15);
        // ftq_in_dat = {tmp_f1, tmp_f0};

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

        // #0; dut.print_pc_gen; // 0 delay ensures all combinational signals have settled before printing
        // @(posedge clock);


        // $display("Test 1:");
        // reset = 1;
        // s_rst = '0;
        // @(negedge clock);
        // // code
        // @(posedge clock);

        // @(negedge clock);


    // end
    end
`endif

endmodule