`include "sys_defs.svh"

module global_history_register(
    input logic clock, reset,

    input retire2predictor ret_2_pred,

    //input 
    //input logic update,
    //input logic taken,

    output logic [7:0] globalBHR
    
);

    always_ff @(posedge clock) begin
            if (reset) begin 
                globalBHR <= 8'b0; 
            end else if (ret_2_pred.update_enable) begin
                globalBHR <= {globalBHR[6:0], ret_2_pred.taken}; 
            end
    end

endmodule
