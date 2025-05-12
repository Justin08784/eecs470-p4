`include "sys_defs.svh"

/* 
================================================
Retire (Manager)
================================================
*/
typedef enum logic [2:0] {
    RET_GEN = 'd0,
    RET_HLT = 'd1,
    RET_ILL = 'd2,
    RET_LOD = 'd3,
    RET_STR = 'd4,
    RET_BRU = 'd5
} RETIRE_OP;

module retire (
`ifdef DEBUG
    output DBG_retire dbg,
`endif
    input  clock, reset,

    input  rob2retire rob_in,
    // output retire2rob rob_out,

    input  btq2retire btq_in,
    output retire2btq btq_out,

    output logic flush,
    output WADDR flush_PC,
    output retire_final retire_exec
);
    // decode retire operations
    RETIRE_OP [`N-1:0] ret;
    always_comb begin
        foreach (ret[i]) begin
            ret[i] = RET_GEN;

            unique case (rob_in.entries[i].fu_idx)
            FU_LOAD:    ret[i] = RET_LOD;
            FU_STORE:   ret[i] = RET_STR;
            FU_BRU:     ret[i] = RET_BRU;
            endcase

            if (rob_in.entries[i].illegal)
                ret[i] = RET_ILL;
            else if (rob_in.entries[i].halt)
                ret[i] = RET_HLT;
        end
    end

    // general retire
    logic [$clog2(`N):0] r_en_cnt;

    // bru retire
    logic [$clog2(`N):0] btq_rd_cnt;
    logic mispred;
    WADDR mispred_tgt;
    logic [$clog2(`N):0] puq_credits;

    always_comb begin
        r_en_cnt    = 0;

        mispred     = 1'b0;
        mispred_tgt = '0;
        btq_rd_cnt  = 0;
        puq_credits = btq_in.puq_rdy_scnt;

        for (int i = 0; i < rob_in.r_vld_cnt; ++i) begin
            if (!rob_in.entries[i].cpl)
                break;

            unique case (ret[i])
            RET_GEN,
            RET_HLT,
            RET_ILL,
            RET_LOD,
            RET_STR: begin
                ++r_en_cnt;
            end

            RET_BRU: begin
                logic pred;
                logic take;
                logic corr_tgt;
                WADDR npc;
                WADDR tgt;

                pred     = btq_in.dat[btq_rd_cnt].pred;
                take     = btq_in.dat[btq_rd_cnt].take;
                corr_tgt = btq_in.dat[btq_rd_cnt].pred_tgt == btq_in.dat[btq_rd_cnt].tgt;
                npc      = btq_in.dat[btq_rd_cnt].PC + 1;
                tgt      = btq_in.dat[btq_rd_cnt].tgt;

                if (puq_credits == 0)
                    break;
                --puq_credits;
                ++r_en_cnt;
                ++btq_rd_cnt;

                unique casez ({pred, take, corr_tgt})
                3'b010,
                3'b011,
                3'b110: begin
                    mispred = 1;
                    mispred_tgt = tgt;
                    break;
                end

                3'b100,
                3'b101: begin
                    mispred = 1;
                    mispred_tgt = npc;
                    break;
                end

                default:;
                endcase
            end
            endcase
        end
    end

    logic flush_n;
    WADDR flush_PC_n;
    always_comb begin
        flush_n     = mispred;
        flush_PC_n  = mispred_tgt;

        /* Retire should not act while flush is high */
        btq_out = flush ? '0 : '{
            rd_cnt : btq_rd_cnt
        };
    end

    always_comb begin
        PHYS_REG_IDX [`N-1:0] tag;
        PHYS_REG_IDX [`N-1:0] t_old;
        REG_IDX      [`N-1:0] dst;
        logic        [`N-1:0] halt;
        logic        [`N-1:0] illegal;

        for (int i = 0; i < `N; ++i) begin
            tag[i]     = rob_in.entries[i].tag;
            t_old[i]   = rob_in.entries[i].t_old;
            dst[i]     = rob_in.entries[i].dst;
            halt[i]    = rob_in.entries[i].halt;
            illegal[i] = rob_in.entries[i].illegal;
        end

        retire_exec = flush ? '0 : '{
            // only the count *may* be adjusted
            r_en_cnt : r_en_cnt,

            // the rest of the fields stay the same
            tag      : tag,
            t_old    : t_old,
            dst      : dst,
            halt     : halt,
            illegal  : illegal
        };
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            /* Even the flush must flush itself.

            Pulse flush for 1 cycle. Ensures branches on mispredicted
            control path cannot retrigger. */
            flush       <= '0;
            flush_PC    <= '0;
        end else begin
/* ======================================== */
            flush       <= flush_n;
            flush_PC    <= flush_PC_n;
/* ======================================== */
        end
    end

`ifdef DEBUG
    assign dbg = '{
        rob_in,
        btq_in,
        btq_out,
        mispred,
        mispred_tgt,
        retire_exec
    };
`endif
endmodule
