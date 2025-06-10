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
    input  clock, reset,

    input  rob2retire rob_in,

    output retire_final retire_exec
);
    // decode retire operations
    RETIRE_OP [`N-1:0] ret;
    always_comb begin
        foreach (ret[i]) begin
            unique case (rob_in.entries[i].fu_idx)
            FU_LOD: ret[i] = RET_LOD;
            FU_STR: ret[i] = RET_STR;
            FU_BRU: ret[i] = RET_BRU;
            default:ret[i] = RET_GEN;
            endcase

            if (rob_in.entries[i].illegal)
                ret[i] = RET_ILL;
            else if (rob_in.entries[i].halt)
                ret[i] = RET_HLT;
        end
    end

    // general retire
    `CNT_TYPE(`N) r_en_cnt;

    always_comb begin
        r_en_cnt    = 0;

        for (int i = 0; i < rob_in.r_vld_cnt; ++i) begin
            if (!rob_in.entries[i].cpl)
                break;

            unique case (ret[i])
            RET_GEN,
            RET_HLT,
            RET_ILL,
            RET_LOD,
            RET_BRU,
            RET_STR: begin
                ++r_en_cnt;
            end
            endcase
        end
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

        // retire_exec = flush ? '0 : '{
        retire_exec = '{
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

`ifdef DEBUG
    task print_retire;
        $display("  | >> retire >>");

        $display("retire_exec.r_en_cnt: %0d", retire_exec.r_en_cnt);
        $display("  | << retire <<");
    endtask
`endif
endmodule
