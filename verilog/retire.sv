`include "sys_defs.svh"

/* 
================================================
Retire (Manager)
================================================
*/
module retire (
    `ifdef DEBUG
    output DBG_retire dbg,
    `endif
    input clock, reset,

    input  rob2retire rob_in,
    // output retire2rob rob_out,

    input  btq2retire btq_in,
    output retire2btq btq_out,

    input  sq2retire sq_in,
    output retire2sq sq_out,

    input lq2retire lq_in,

    output retire2lq lq_out,

    output logic flush,
    output ADDR  corrected_PC,
    output logic [`N-1:0] branch_taken,
    output logic [`N-1:0] update_en,
    output ADDR [`N-1:0] PC_original,
    output logic [`N-1:0] [7:0] bhr_from_btq,


    output logic [`N-1:0] [7:0] correlated_bhr_d,
    output logic [`N-1:0] gshare_pred,
    output logic [`N-1:0] corr_pred, 
    //output retire2fetch ret_2_fetch,

    output logic mispred_taken, 

    output retire_final retire_exec
);
    logic [$clog2(`N):0] r_en_cnt;
    logic [$clog2(`N):0] btq_rd_cnt;
    logic [$clog2(`N):0] sq_rd_cnt;
    logic [$clog2(`N):0] lq_rd_cnt;

    PHYS_REG_IDX [`N-1:0] tmp_tag;
    PHYS_REG_IDX [`N-1:0] tmp_t_old;
    REG_IDX      [`N-1:0] tmp_dst;
    logic        [`N-1:0] tmp_halt;
    logic        [`N-1:0] tmp_illegal;
    logic        [`N-1:0] tmp_is_brch;

    logic mispred;
    ADDR  mispred_target;
    logic ld_ooo;
    ADDR  ld_PC;

    logic flush_n;
    ADDR  corrected_PC_n;

    logic [`N-1:0] branch_taken_n;
    logic [`N-1:0] update_en_n;
    ADDR [`N-1:0] PC_original_n;
    logic [`N-1:0] [7:0] bhr_from_btq_n;


    logic [`N-1:0] [7:0] correlated_bhr_d_n;
    logic [`N-1:0] gshare_pred_n;
    logic [`N-1:0] corr_pred_n;
    logic store_retire;

    logic mispred_taken_n;
    
    always_comb begin
        sq_out = '0;
        store_retire = 0;

        mispred = 0;
        mispred_target = '0;
        ld_ooo = 0;
        ld_PC = '0;

        r_en_cnt    = 0;
        btq_rd_cnt  = 0;
        sq_rd_cnt   = 0;
        lq_rd_cnt   = 0;

        branch_taken_n = '0;
        update_en_n = '0;
        PC_original_n = '0;
        bhr_from_btq_n = '0;

        correlated_bhr_d_n = '0;
        gshare_pred_n = '0;
        corr_pred_n = '0;

        mispred_taken_n = '0;

        btq_out = '0;



        for (int i = 0; i < rob_in.r_vld_cnt; ++i) begin
            if (!rob_in.entries[i].cpl)
                break;
            if (rob_in.entries[i].halt && (!sq_in.sq_ret_complete || i != 0)) begin
                /* A halt may retire IFF 
                a) The ret buffer is empty (i.e. retired to memory) 
                b) The halt is at the head of the ROB (i.e. i == 0). 
                
                (b. addresses the edge case where instructions in the same retire
                batch, before the halt, are stores. Next cycle the ret buffer
                will not be empty.)
                */
                break;
            end

            if (rob_in.entries[i].rd_mem) begin
                // if (0) begin // TODO: enable when lq_in.err_ld_ooo is actually set
                if (lq_in.err_ld_ooo[lq_rd_cnt]) begin
                    ld_ooo  = 1;
                    ld_PC   = lq_in.PC[lq_rd_cnt];
                    break;
                end
                ++lq_rd_cnt; 
            end

            if (rob_in.entries[i].wr_mem) begin
                if (sq_rd_cnt >= sq_in.sq_ret_en)
                    break;
                ++sq_rd_cnt; 
            end
            
            ++r_en_cnt;

            if (!rob_in.entries[i].is_brch)
                continue;

            update_en_n[i] = 1;

            PC_original_n[i] = btq_in.dat[btq_rd_cnt].PC;

            bhr_from_btq_n[i] = btq_in.dat[btq_rd_cnt].bhr;
            correlated_bhr_d_n[i] = btq_in.dat[btq_rd_cnt].correlated_bhr;

            gshare_pred_n[i] = btq_in.dat[btq_rd_cnt].gshare_pred;
            corr_pred_n[i] = btq_in.dat[btq_rd_cnt].corr_pred;
            $display("BTQ_IN PC: 0x%x, BTQ_IN TGT: 0x%x} ", btq_in.dat[btq_rd_cnt].PC, btq_in.dat[btq_rd_cnt].tgt);
            $display("BTQ_IN PRED: %x,  BTQ_IN TAKE: %x", btq_in.dat[btq_rd_cnt].pred, btq_in.dat[btq_rd_cnt].take);        
            if (btq_in.dat[btq_rd_cnt].pred != btq_in.dat[btq_rd_cnt].take) begin
                // is mispred?
                mispred = 1;
                mispred_target = btq_in.dat[btq_rd_cnt].take
                    ? btq_in.dat[btq_rd_cnt].tgt
                    : btq_in.dat[btq_rd_cnt].NPC;

                branch_taken_n[i] = btq_in.dat[btq_rd_cnt].take ? 1'b1 : 1'b0;

                mispred_taken_n = btq_in.dat[btq_rd_cnt].take ? 1'b1 : 1'b0;

                ++btq_rd_cnt;
                break;
            end
            else if (btq_in.dat[btq_rd_cnt].take && (btq_in.dat[btq_rd_cnt].pred_tgt != btq_in.dat[btq_rd_cnt].tgt)) begin
                mispred = 1;
                mispred_target = btq_in.dat[btq_rd_cnt].tgt;

                branch_taken_n[i] = 1'b1;

                ++btq_rd_cnt;
                break;
            end /*else begin
                 branch_taken_n[i] = btq_in.dat[btq_rd_cnt].take ? 1'b1 : 1'b0;
            end*/
            ++btq_rd_cnt;
        end

        flush_n = mispred || ld_ooo;
        corrected_PC_n = mispred
            ? mispred_target
            : ld_ooo
                ? ld_PC
                : '0;

        for (int i = 0; i < `N; ++i) begin
            tmp_tag[i]     = rob_in.entries[i].tag;
            tmp_t_old[i]   = rob_in.entries[i].t_old;
            tmp_dst[i]     = rob_in.entries[i].dst;
            tmp_halt[i]    = rob_in.entries[i].halt;
            tmp_illegal[i] = rob_in.entries[i].illegal;
            tmp_is_brch[i] = rob_in.entries[i].is_brch;
        end

        /* Retire should not act while flush is high */
        btq_out = flush ? '0 : '{
            rd_cnt : btq_rd_cnt
        };
        
        retire_exec = flush ? '0 : '{
            // only the count *may* be adjusted
            r_en_cnt : r_en_cnt,

            // the rest of the fields stay the same
            tag      : tmp_tag,
            t_old    : tmp_t_old,
            dst      : tmp_dst,
            halt     : tmp_halt,
            illegal  : tmp_illegal,
            is_brch  : tmp_is_brch
        };

        sq_out = flush ? '0 : '{
            r_en : sq_rd_cnt
        };

        lq_out = flush ? '0 : '{
            r_en : lq_rd_cnt
        };
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            /* Even the flush must flush itself.

            Pulse flush for 1 cycle. Ensures branches on mispredicted
            control path cannot retrigger. */
            flush        <= '0;
            corrected_PC <= '0;


            branch_taken <= '0;
            update_en    <= '0;
            PC_original  <= '0;
            bhr_from_btq <= '0;


            correlated_bhr_d <= '0;
            gshare_pred      <= '0;
            corr_pred        <= '0;

            mispred_taken    <= '0;

        end else begin
/* ======================================== */
            flush        <= flush_n;
            corrected_PC <= corrected_PC_n;

            branch_taken <= branch_taken_n;
            update_en    <= update_en_n;
            PC_original  <= PC_original_n;
            bhr_from_btq <= bhr_from_btq_n;


            correlated_bhr_d <= correlated_bhr_d_n;
            gshare_pred      <= gshare_pred_n;
            corr_pred        <= corr_pred_n;

            mispred_taken    <= mispred_taken_n;
/* ======================================== */
        end
    end

    // Debugging asserts
    always_ff @(posedge clock) begin
        if (!reset) begin
            if (mispred && ld_ooo) begin
                $error("Retire: both flush conditions set!");
                $fatal;
            end
        end
    end

    `ifdef DEBUG
    assign dbg = '{
        rob_in,
        btq_in,
        btq_out,
        sq_in,
        sq_out,
        lq_in,
        mispred,
        mispred_target,
        retire_exec
    };
    `endif
endmodule
