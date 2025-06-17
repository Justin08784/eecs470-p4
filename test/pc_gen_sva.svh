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
    type FB_OFF = `IDX_TYPE(NUM_W)
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
                dut_comb, dut_comb_n;
    SEQ_LINES   sva_seq, sva_seq_n,
                dut_seq, dut_seq_n;

    assign sva_comb_n   = '0;
    assign sva_seq_n    = '0;
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

    assign diff_n = '{
        off             : sva_seq_n.off     != off,
        base            : sva_seq_n.base    != base,
        inbuf           : sva_seq_n.inbuf   != inbuf,

        ftq_out_ren_cnt : sva_comb_n.ftq_out_ren_cnt  != ftq_out_ren_cnt,
    
        ixq_out_wen_cnt : sva_comb_n.ixq_out_wen_cnt  != ixq_out_wen_cnt,
        ixq_out_dw      : sva_comb_n.ixq_out_dw       != ixq_out_dw,
        ixq_out_fmsk    : sva_comb_n.ixq_out_fmsk     != ixq_out_fmsk,
        ixq_out_is_end  : sva_comb_n.ixq_out_is_end   != ixq_out_is_end,

        buf_out_wen_cnt : sva_comb_n.buf_out_wen_cnt  != buf_out_wen_cnt,
        buf_out_dat     : sva_comb_n.buf_out_dat      != buf_out_dat
    };


    always_ff @(posedge clock) begin
        if (reset) begin
            sva_comb<= '0;
            sva_seq <= '0;
            dut_comb<= '0;
            dut_seq <= '0;
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