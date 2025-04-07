`include "sys_defs.svh"

/* 
================================================
Retire (Manager)
================================================
*/
module retire (
    input clock, reset,

    input  rob2retire rob_in,
    // output retire2rob rob_out,

    input  btq2retire btq_in,
    output retire2btq btq_out,

    // input  sq2retire sq_in,
    // output retire2sq sq_out,

    output logic mispred,
    output ADDR  mispred_target,
    output retire_final retire_exec
);
    logic [$clog2(`N):0] btq_rd_cnt;
    logic [$clog2(`N):0] allowed_retire_cnt; // FUCK ME

    always_comb begin
        mispred = 0;
        mispred_target = '0;
        btq_rd_cnt = 0;
        allowed_retire_cnt = 0;
        for (int unsigned i = 0; i < rob_in.r_en_cnt; ++i) begin
            ++allowed_retire_cnt;
            if (!rob_in.is_brch[i])
                continue;

            if (btq_in.dat[btq_rd_cnt].pred != btq_in.dat[btq_rd_cnt].take) begin
                // is mispred?
                mispred = 1;
                mispred_target = btq_in.dat[btq_rd_cnt].take
                    ? btq_in.dat[btq_rd_cnt].tgt
                    : btq_in.dat[btq_rd_cnt].NPC;
                ++btq_rd_cnt;
                break;
            end 
            ++btq_rd_cnt;
        end

        btq_out = '{
            rd_cnt : btq_rd_cnt
        };

        retire_exec = '{
            // only the count *may* be adjusted
            r_en_cnt    : allowed_retire_cnt,

            // the rest of the fields stay the same
            tag         : rob_in.tag,
            t_old       : rob_in.t_old,
            dst         : rob_in.dst,
            halt        : rob_in.halt,
            illegal     : rob_in.illegal,
            is_brch    : rob_in.is_brch
        };
    end
endmodule
