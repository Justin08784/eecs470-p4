`include "sys_defs.svh"


module gshare_predictor(
    input logic clock, reset,
    input ADDR  branch_PC,
    input logic branch_taken,
    output logic predict_taken
);

    logic [7:0] globalBHR; 
    logic [7:0] index;      
    logic       phtPredict; 



    global_history_register ghr (
            .clk(clock),
            .rst(reset),
            .update(branch_taken),
            .taken(branch_taken),
            .globalBHR(globalBHR)
        );

    assign index = branchPC[7:0] ^ globalBHR;

    pattern_history_table pht (
        .clk(clock),
        .rst(reset),
        .index(index),
        .update(branch_taken),
        .taken(branch_taken),
        .predict(phtPredict)
    );

    
    assign predict_taken = phtPredict;    

endmodule



module correlated_predictor (
    input logic clock, reset,
    input ADDR branch_PC,
    input logic branch_taken,
    output logic predict_taken
);

    logic [7:0] branchHistory;  
    logic        phtPredict;    

    branch_history_table bht (
        .clk(clock),
        .rst(reset),
        .branchPC(branch_PC),
        .update(branch_taken),
        .taken(branch_taken),
        .branchHistory(branchHistory)
    );  

    pattern_history_table pht (
        .clk(clock),
        .rst(reset),
        .index(branchHistory),  
        .update(branch_taken),
        .taken(branch_taken),
        .predict(phtPredict)
    );

    assign predict_taken = phtPredict;  

endmodule



module tournament_predictor (
    input logic clock, reset,
    input ADDR  branch_PC,
    input logic branch_taken,
    output logic predict_taken
);

logic gshare_prediction, correlated_prediction;
logic gshare_correct, correlated_correct;
logic [1:0] chosser_state;

gshare_predictor gshare (
    .clock(clock),
    .reset(reset),
    .branch_pc(branch_PC)
    .branch_taken(branch_taken)
    .preidct_taken(gshare_prediction)

);

correlated_predictor correlated(
    .clock(clock),
    .reset(reset),
    .branch_PC(branch_PC),
    .branch_taken(branch_taken),
    .predict_taken(correlated_prediction)
);

assign gshare_correct = (gshare_prediction == branch_taken);
assign correlated_correct = (correlated_prediction == branch_taken);





//write chooser table

endmodule