`include "sys_defs.svh"

`ifdef  PC_GEN_TEST_MODE
`ifndef PC_GEN_SVA_SVH
`define PC_GEN_SVA_SVH

// `define PC_GEN_SYNTH_MODE
// `ifndef PC_GEN_SYNTH_MODE
// `define PC_GEN_TEST_MODE
// `endif


typedef struct packed {
    // int         id;
    DWADDR      dw;     // cache line to which it belongs
    logic       is_end; // is end of fb?

    WADDR       base;   // fb base
    logic[3:0]  off;    // in-fb offset

    // logic       ft;     // was fb predicted fallthrough?
    // logic       fmsk;   // fetchable?
    // FTQ_ENTRY   fb;     // fb to which it belongs
} WORD_STREAM_PKT;

// TODO: need a check that buf is written AS SOON as any block in
// the corresponding ftq entry is consumed
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
    input pc_gen2ixq dat,

    output int  num     // of packets produced
);
    WORD_STREAM_PKT [1:0] rv;
    WADDR   line_start, cur_pc;
    int     w;

    line_start = dat.dw << 1;

    rv = '0;

    num = 0;
    for (w = 0; w < 2; ++w) begin
        cur_pc  = line_start + w;
        if (!dat.fmsk[w])
            continue;

        rv[num] = '{
            dw      : dat.dw,
            is_end  : dat.is_end[w],
            base    : cur_pc - dat.off[w],
            off     : dat.off[w]
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
    input   pc_gen2ixq[1:0] ixq_out_dat,

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
        pc_gen2ixq[1:0] ixq_out_dat;
        // FTQ buffer
        `CNT_TYPE(2)    buf_out_wen_cnt;
        FTQ_ENTRY[1:0]  buf_out_dat;
    } COMB_LINES;

    int     id, id_n;
    int     buf_id, buf_id_n;
    int     end_cnt, end_cnt_n;
    WORD_STREAM_PKT in_stream [$];
    WORD_STREAM_PKT [16*NUM_DW-1:0] in_append;
    WORD_STREAM_PKT [NUM_W*NUM_DW-1:0] out_stream, in_cons;
    int wr_idx;
    int in_stream_sz, in_append_cnt, in_cons_cnt;
    int out_stream_sz, out_stream_sz_n;

    logic match_stream; // do the streams match?
    logic buf_id_increasing;
    // logic not_write_buf_after_emit;
    // not_write_buf_after_emit = 1;
    // for (int w = 0; w < out_stream_sz_n; ++w)
    //     not_write_buf_after_emit &= out_stream[w].id < buf_id_n;

    struct packed {
        WADDR base;
        logic [3:0] off;
    } cur, cur_n;

    initial begin
    forever begin

        @(negedge clock);
        in_stream_sz = in_stream.size();
        // for (int w = 0; w < in_stream_sz; ++w)
        //     $display("in_st[%2d]: base: %d, off: %d, is_end: %b, dw: %d",
        //         w,
        //         in_stream[w].base,
        //         in_stream[w].off,
        //         in_stream[w].is_end,
        //         in_stream[w].dw
        //     );

        // for (int w = 0; w < out_stream_sz; ++w)
        //     $display("ot_st[%2d]: base: %d, off: %d, is_end: %b, dw: %d",
        //         w,
        //         out_stream[w].base,
        //         out_stream[w].off,
        //         out_stream[w].is_end,
        //         out_stream[w].dw
        //     );

        in_cons_cnt  = out_stream_sz;
        match_stream = 1;
        for (int w = 0; w < in_cons_cnt; ++w) begin
            WORD_STREAM_PKT cur;
            logic cur_match;

            cur = in_stream.pop_front();
            in_cons[w] = cur;
            match_stream &= cur == out_stream[w];
        end


        buf_id_n = buf_id;
        buf_id_increasing = 1;
        for (int w = 0; w < buf_out_wen_cnt; ++w) begin
            buf_id_increasing &= buf_out_dat[w].id == (buf_id_n+1);
            ++buf_id_n;
        end

        // $display("dicr buf_id: %d", buf_id);
        // $display("buf_out: wen_cnt = %d, [{id %4d, base_n: %d, ft: %b, off: %d}, {id: %4d, base_n: %d, ft: %b, off: %d}]\n",
        //     buf_out_wen_cnt,
        //     buf_out_dat[0].id,
        //     buf_out_dat[0].base_n,
        //     buf_out_dat[0].ft,
        //     buf_out_dat[0].off,
        //     buf_out_dat[1].id,
        //     buf_out_dat[1].base_n,
        //     buf_out_dat[1].ft,
        //     buf_out_dat[1].off
        // );


        id_n    = id;
        cur_n   = cur;

        wr_idx  = 0;
        for (int e = 0; e < ftq_in_vld_scnt; ++e) begin
            FTQ_ENTRY fb;
            WORD_STREAM_PKT [15:0] tmp;
            int tmp_cnt;

            fb = ftq_in_dat[e];
            // $display("add: e: %d, fb.id: %d (%d)", e, fb.id, id);
            if (fb.id < id) // already added
                continue;

            tmp = fb2stream(fb, cur_n.base, cur_n.off, tmp_cnt);
            for (int w = 0; w < tmp_cnt; ++w) begin
                in_append[wr_idx] = tmp[w];
                ++wr_idx;
            end

            // assert(!ftq_ids.exists(cur_id));
            // ftq_ids[cur_id] = 1;

            cur_n.base = fb.base_n;
            cur_n.off  = 0;

            ++id_n;
        end
        in_append_cnt = wr_idx;


        wr_idx = 0;
        for (int e = 0; e < ixq_out_wen_cnt; ++e) begin
            WORD_STREAM_PKT [1:0] tmp;
            int tmp_cnt;

            tmp = ixq_out2stream(
                ixq_out_dat[e],
                tmp_cnt
            );

            for (int w = 0; w < tmp_cnt; ++w) begin
                out_stream[wr_idx] = tmp[w];
                ++wr_idx;
            end
        end
        out_stream_sz_n = wr_idx;

        end_cnt_n = end_cnt;
        for (int w = 0; w < out_stream_sz_n; ++w)
            end_cnt_n += out_stream[w].is_end;


        @(posedge clock);
    end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            id <= '0;
            buf_id <= -1;
            end_cnt <= 0;
            cur     <= '{
                base: reset_val.base,
                off : reset_val.off
            };
            in_stream.delete();
            out_stream_sz <= '0;

        end else if (flush) begin
            id <= '0;
            buf_id <= -1;
            end_cnt <= 0;
            cur <= '{
                base: flush_fb_base,
                off : flush_pc_off
            };
            in_stream.delete();
            out_stream_sz <= '0;

        end else begin
            id  <= id_n;
            buf_id <= buf_id_n;
            end_cnt <= end_cnt_n;
            cur <= cur_n;
            for (int w = 0; w < in_append_cnt; ++w)
                in_stream.push_back(in_append[w]);
            out_stream_sz <= out_stream_sz_n;

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

        $display("ixq_out: wen_cnt = %d, off = [[%d, %d], [%d, %d]], fmsk = [%b, %b], is_end = [%b, %b], dw = [%d, %d]",
            c.ixq_out_wen_cnt,
            c.ixq_out_dat[0].off[0],
            c.ixq_out_dat[0].off[1],
            c.ixq_out_dat[1].off[0],
            c.ixq_out_dat[1].off[1],
            c.ixq_out_dat[0].fmsk,
            c.ixq_out_dat[1].fmsk,
            c.ixq_out_dat[0].is_end,
            c.ixq_out_dat[1].is_end,
            c.ixq_out_dat[0].dw,
            c.ixq_out_dat[1].dw
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
    endtask

    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            debug;
            $display("incr: %b", buf_id_increasing);
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        property in_stream_eqlonger;
            disable iff (reset)
            in_stream_sz >= out_stream_sz;
        endproperty

        property in_eq_out;
            disable iff (reset)
            match_stream;
        endproperty

        property buf_id_sequential;
            disable iff (reset)
            buf_id_increasing;
        endproperty

        property ends_lockstepw_buf_writes;
            disable iff (reset)
            /* Each fb has exactly 1 end. Thus, the number of encountered ends
            should increment no faster than the number of FTQ entries written to
            the re-read buffer, but no slower than 1 behind. 
            (buf_id+1 = number FTQ entries written) */
            (end_cnt == buf_id) || (end_cnt == buf_id+1);
        endproperty

    endclocking

    In_Stream_EqLonger: assert property(cb.in_stream_eqlonger)
        else exit_on_error;
    In_Eq_Out: assert property(cb.in_eq_out)
        else exit_on_error;
    Buf_Id_Sequential: assert property(cb.buf_id_sequential)
        else exit_on_error;
    Ends_Lockstepw_Buf_Writes: assert property(cb.ends_lockstepw_buf_writes)
        else exit_on_error;

endmodule
`endif // PC_GEN_SVA_SVH
`endif // PC_GEN_TEST_MODE