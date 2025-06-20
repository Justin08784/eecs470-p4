`include "sys_defs.svh"
`include "test/pc_gen_sva.svh"

`ifdef PC_GEN_TEST_MODE

// stimulus engine
/* NOTE:

The negedge, posedge placements in the initial blocks of stim and sva are nuanced.
stim: ... do stuff ... negedge posedge
sva:  negedge ... do stuff ... posedge

This ensures that stim always acts before sva each cycle, removing races.
*/
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
    input   pc_gen2ixq[1:0] ixq_out_dat,

    // FTQ buffer
    output  `CNT_TYPE(2)    buf_in_rdy_scnt,
    input   `CNT_TYPE(2)    buf_out_wen_cnt,
    input   FTQ_ENTRY[1:0]  buf_out_dat
);
    localparam _FTQ_SZ = 8;
    localparam _BUF_SZ = 8;

    FTQ_ENTRY _ftq [$], _buf [$];
    logic ftq_ids[int];
    // does id exist in X? (doesn't need to have logic type, but SV doesn't support sets... right?)

    int ftq_sz, buf_sz, num_add, num_del;

    int cur_id, cur_id_n;
    struct packed {
        WADDR base;
        logic [3:0] off;
    } cur, cur_n;

    localparam FLUSH_PROB = 8; // in percent
    logic [1:0] ftq_in_vld_max;
    logic [1:0] ixq_in_rdy_max;
    logic [1:0] buf_in_rdy_max;
    logic [1:0] buf_cons_max;

    initial begin
        flush           = 0;
        flush_fb_base   = '0;
        flush_pc_off    = '0;

        ftq_in_vld_scnt = 0;
        ftq_in_dat      = '0;
        ixq_in_rdy_scnt = 0;
        buf_in_rdy_scnt = 0;

    // forever begin
    repeat (1000) begin
    // repeat (1000000) begin
        cur_id_n = cur_id;
        cur_n = cur;

        ftq_sz = _ftq.size();
        buf_sz = _buf.size();

        ftq_in_vld_max = $urandom_range(2, 0);
        ixq_in_rdy_max = $urandom_range(2, 0);
        buf_in_rdy_max = $urandom_range(2, 0);
        buf_cons_max   = $urandom_range(2, 0);

        // $display("cur: id: %4d, base: %d", cur_id, cur.base);
        // for (int e = 0; e < ftq_sz; ++e)
        //     $display("ftq[%1d]: off: %d, ft: %b, base_n: %d (id: %0d)",
        //         e,
        //         _ftq[e].off,
        //         _ftq[e].ft,
        //         _ftq[e].base_n,
        //         _ftq[e].id
        //     );
        // for (int e = 0; e < buf_sz; ++e)
        //     $display("buf[%1d]: off: %d, ft: %b, base_n: %d (id: %0d)",
        //         e,
        //         _buf[e].off,
        //         _buf[e].ft,
        //         _buf[e].base_n,
        //         _buf[e].id
        //     );

        std::randomize(flush_pc_off);
        std::randomize(flush_fb_base);
        flush = $urandom_range(99, 0) < FLUSH_PROB;
        // $display("flush: %b, %d %d", flush, flush_fb_base, flush_pc_off);
        // $display("cur_id: %d, cur_id_n: %d", cur_id, cur_id_n);

        ftq_in_vld_scnt = `MIN(ftq_sz, ftq_in_vld_max);
        ftq_in_dat = '0;
        for (int e = 0; e < ftq_in_vld_scnt; ++e)
            ftq_in_dat[e] = _ftq[e];
        ixq_in_rdy_scnt = ixq_in_rdy_max;
        buf_in_rdy_scnt = `MIN(_BUF_SZ-buf_sz, buf_in_rdy_max);

        num_add = _FTQ_SZ-ftq_sz;
        for (int e = 0; e < num_add; ++e) begin
            // localparam MAX_OFF_VAL = 1 << 15 - MAX_W_PER_FB; // FIXME: how to handle?
            FTQ_ENTRY fb;

            std::randomize(fb);

            if (cur_n.off > fb.off)
                fb.off = cur_n.off;

            if (fb.ft)
                fb.base_n = cur_n.base + fb.off + 1;

            fb.id = cur_id_n;
            _ftq.push_back(fb);

            assert(!ftq_ids.exists(cur_id_n));
            ftq_ids[cur_id_n] = 1;

            ++cur_id_n;
            cur_n.base = fb.base_n;
            cur_n.off  = 0;
        end

        // consume some buffer entries
        num_del = `MIN(buf_sz, buf_cons_max);
        for (int e = 0; e < num_del; ++e) begin
            FTQ_ENTRY fb;
            if (ftq_ids.exists(_buf[e].id))
                break;

            fb = _buf.pop_front();
        end


        // >>>>
        // >>>>>>>>
        @(negedge clock);
        // <<<<<<<<
        // <<<<

        if (reset) begin
            _ftq.delete();
            _buf.delete();
            ftq_ids.delete();

            cur_id <= 0;
            cur <= '{
                base: reset_val.base,
                off : reset_val.off
            };

        end else if (flush) begin
            _ftq.delete();
            _buf.delete();
            ftq_ids.delete();

            cur_id <= 0;
            cur <= '{
                base: flush_fb_base,
                off : flush_pc_off
            };

        end else begin
            cur_id <= cur_id_n;
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
            end
        end

        // >>>>
        // >>>>>>>>
        @(posedge clock);
        // <<<<<<<<
        // <<<<
    end

        $finish;
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
    pc_gen2ixq[1:0] ixq_out_dat;
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
        .ixq_out_dat,

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
        .ixq_out_dat,

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
        .ixq_out_dat,

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
    end
`endif

endmodule