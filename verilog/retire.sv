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

    output retire2lq lq_out,

    output logic mispred,
    output ADDR  mispred_target,
    output retire_final retire_exec
);
    logic [$clog2(`N):0] r_en_cnt;
    logic [$clog2(`N):0] btq_rd_cnt;
    logic [$clog2(`N):0] sq_rd_cnt;

    PHYS_REG_IDX [`N-1:0] tmp_tag;
    PHYS_REG_IDX [`N-1:0] tmp_t_old;
    REG_IDX      [`N-1:0] tmp_dst;
    logic        [`N-1:0] tmp_halt;
    logic        [`N-1:0] tmp_illegal;
    logic        [`N-1:0] tmp_is_brch;

    always_comb begin
        // FIXME: >>
        // sq_out logic migrated from rob (when it still had rob2sq)
        sq_out = '0;
        //tell SQ to retire entries
        // if (state[rtre_idxs[i]].wr_mem)
        //     ++sq_out.r_en;
        // FIXME: <<

        mispred = 0;
        mispred_target = '0;

        r_en_cnt = 0;
        btq_rd_cnt = 0;
        sq_rd_cnt  = 0;
        for (int i = 0; i < rob_in.r_vld_cnt; ++i) begin
            if (!rob_in.entries[i].cpl)
                break;
            if (rob_in.entries[i].halt && !sq_in.sq_ret_complete)
                break;

            ++r_en_cnt;
            // if (rob_in.entries[i].wr_mem && (sq_rd_cnt < sq_in.ret_rdy))
            //     ++sq_rd_cnt; // TODO: assign to sq_out.r_en
            // FIXME: Is checking sq_in.ret_rdy even necessary?

            if (!rob_in.entries[i].is_brch)
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

        for (int i = 0; i < `N; ++i) begin
            tmp_tag[i]     = rob_in.entries[i].tag;
            tmp_t_old[i]   = rob_in.entries[i].t_old;
            tmp_dst[i]     = rob_in.entries[i].dst;
            tmp_halt[i]    = rob_in.entries[i].halt;
            tmp_illegal[i] = rob_in.entries[i].illegal;
            tmp_is_brch[i] = rob_in.entries[i].is_brch;
        end
        
        retire_exec = '{
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
    end

    `ifdef DEBUG
    assign dbg = '{
        rob_in,
        btq_in,
        btq_out,
        sq_in,
        sq_out,
        mispred,
        mispred_target,
        retire_exec
    };
    `endif
endmodule
