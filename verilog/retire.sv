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
    input  rob2retire rob_in,

    output RETIRE_PKT retire_exec
);
    // decode retire operations
    RETIRE_OP [N-1:0] ret;
    always_comb begin
        for (int i = 0; i < N; ++i) begin
            unique case (rob_in.fu_idx[i])
            FU_LOD: ret[i] = RET_LOD;
            FU_STR: ret[i] = RET_STR;
            FU_BRU: ret[i] = RET_BRU;
            default:ret[i] = RET_GEN;
            endcase

            if (rob_in.illegal[i])
                ret[i] = RET_ILL;
            else if (rob_in.halt[i])
                ret[i] = RET_HLT;
        end
    end

    // general retire
    `CNT_TYPE(N) retire_en_cnt;

    always_comb begin
        retire_en_cnt   = 0;

        for (int i = 0; i < rob_in.vld_scnt; ++i) begin
            if (!rob_in.cpl[i])
                break;

            unique case (ret[i])
            RET_GEN,
            RET_HLT,
            RET_ILL,
            RET_LOD,
            RET_BRU,
            RET_STR: begin
                ++retire_en_cnt;
            end
            endcase
        end
    end

    assign retire_exec = '{
        // only the count *may* be adjusted
        en_cnt  : retire_en_cnt,

        // the rest of the fields stay the same
        t_old   : rob_in.t_old,
        halt    : rob_in.halt,
        illegal : rob_in.illegal
    };


`ifdef DEBUG
    task print_retire;
        $display("  | >> retire >>");

        $display("retire_exec.retire_en_cnt: %0d", retire_exec.retire_en_cnt);
        $display("  | << retire <<");
    endtask
`endif

endmodule
