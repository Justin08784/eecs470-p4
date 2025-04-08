`include "sys_defs.svh"

module global_history_register (
    input  logic        clock,
    input  logic        reset,

    input  retire2predictor ret_2_pred,     // Retirement info for both instructions

    output logic [7:0]  globalBHR           // Current global history (used during fetch)
);

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            globalBHR <= 8'b0;
        end else begin
            case ({ret_2_pred.update_enable[1], ret_2_pred.update_enable[0]})
                2'b00: globalBHR <= globalBHR;
                2'b01: globalBHR <= {globalBHR[6:0], ret_2_pred.taken[0]};
                2'b10: globalBHR <= {globalBHR[6:0], ret_2_pred.taken[1]};
                2'b11: globalBHR <= {globalBHR[5:0], ret_2_pred.taken[0], ret_2_pred.taken[1]};
            endcase
        end
    end


endmodule

