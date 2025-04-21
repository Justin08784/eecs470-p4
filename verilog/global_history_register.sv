`include "sys_defs.svh"

module global_history_register (
    input  logic        clock,
    input  logic        reset,

    input fetch2predictor fetch_2_pred,
    //input  retire2predictor fetch_2_pred,     // Retirement info for both instructions
    input dispatch2predictor dispatch_in,

    output logic [14:0]  globalBHR           // Current global history (used during fetch)
);

   /*always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            globalBHR <= 15'b0;
        end else begin
            case ({fetch_2_pred.update_enable[1], fetch_2_pred.update_enable[0]})
                2'b00: globalBHR <= globalBHR;
                2'b01: globalBHR <= {globalBHR[6:0], fetch_2_pred.taken[0]};
                2'b10: globalBHR <= {globalBHR[6:0], fetch_2_pred.taken[1]};
                2'b11: globalBHR <= {globalBHR[5:0], fetch_2_pred.taken[0], fetch_2_pred.taken[1]};
            endcase
        end
    end*/


    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            globalBHR <= 15'b0;
        end else if(fetch_2_pred.flush) begin
            globalBHR = (globalBHR >> fetch_2_pred.spec_branch_count) << fetch_2_pred.mispred_taken;
        end else begin
            for(int i = 0; i < `N; ++i) begin
                if(dispatch_in.is_branch[i]) begin
                    globalBHR = {globalBHR[6:0],dispatch_in.fetch_pred[i]}; 
                end
            end
        end 
    end



endmodule

