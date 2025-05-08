/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_if.sv                                         //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module stage_if_p4 (
`ifdef DEBUG
    output  DBG_fetch dbg,
`endif

    input   clock,
    input   reset,
    input   flush,
    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   btq2fetch btq_in,
    output  fetch2btq btq_out,

    input   retire2fetch r_in,

    input   mem2fetch mem_in,
    output  fetch2mem mem_out
);
    WADDR PC_reg;       // base PC for this cycle
    WADDR [`N:0] PC_n;  // PC_n[m] := next PC if we fetch "m" this cycle (inaccurate past the 1st branch)

    logic [$clog2(`N):0]    free_scnt, used_scnt, f_cnt;
    logic [`N-1:0]          f_en;
    IF_ID_PACKET [`N-1:0]   f_dat;


    always_comb begin
        logic woff;
        logic [$clog2(`N):0] btq_wr_idx;
        logic [$clog2(`N):0] lim_cnt_btq;
        struct packed {
            logic call;
            logic ret;
            logic cond_branch;
            logic uncond_branch;
        } [`N-1:0] f_md;
        logic [`N-1:0] is_brch;

        f_md = mem_in.f_md;
        foreach (is_brch[i])
            is_brch[i] = f_md[i].cond_branch || f_md[i].uncond_branch;


        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);

        PC_n[0] = PC_reg;
        for (int i = 0; i < `N; ++i) begin
            PC_n[i + 1] = PC_reg + i + 1;
            mem_out.PCs[i] = w2addr(PC_n[i]);
        end

        for (int unsigned i = 0; i < `N; ++i) begin
            woff = PC_n[i][0];

            f_dat[i] = '{
                inst    : mem_in.data[i].word_level[woff],
                PC      : PC_n[i],
                btq_idx : '0    // default; overwrite below
            };
        end

        f_cnt = free_scnt;
        lim_cnt_btq = 0;
        for (int i = 0, int used_cnt = 0; i < `N; ++i) begin
            if (used_cnt + is_brch[i] > btq_in.rdy_scnt)
                break;
            used_cnt += is_brch[i];
            ++lim_cnt_btq;
        end
        f_cnt = `MIN(lim_cnt_btq, f_cnt);


        // handle btq output
        foreach(f_en[i])
            f_en[i] = i < f_cnt;
        btq_out = '{
            en_cnt      : $countones(f_en & is_brch),

            // defaults; overwrite below
            PC          : '0,
            pred        : '0,
            pred_tgt    : '0
        };

        btq_wr_idx  = 0;
        for (int i = 0; i < `N; ++i) begin
            if (!is_brch[i])
                continue;
            f_dat[i].btq_idx = btq_in.btq_idxs[btq_wr_idx];

            btq_out.PC[btq_wr_idx]       = f_dat[i].PC;
            btq_out.pred[btq_wr_idx]     = 1'b0;    // FIXME
            btq_out.pred_tgt[btq_wr_idx] = '0;      // FIXME
            ++btq_wr_idx;
        end
    end

    fifo #(
        .DEPTH(2*`N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) dut (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .wr_en_cnt  (f_cnt),
        .wr_data    (f_dat),
        .rd_en_cnt  (d_out.f_en_cnt),
        .rd_data    (d_out.f_dat),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;                    // initial PC value is 0 (the memory address where our program starts)
        end else if (flush) begin
            PC_reg <= r_in.corrected_PC;    // update to a taken branch (does not depend on valid bit)...
        end else begin
            PC_reg <= PC_n[f_cnt];          // ...or transition to next PC if valid
        end
    end

`ifdef DEBUG
    assign dbg = '{
        flush : flush,
        d_in  : d_in,
        d_out : d_out,
        r_in  : r_in
    };
`endif

endmodule // stage_if
