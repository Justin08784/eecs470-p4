`include "sys_defs.svh"

module chooser_table(
    input  logic        clock, reset,
    input  logic [31:0] branchPC,
    input  logic        gshareCorrect,  
    input  logic        correlatedCorrect,
    output logic [1:0]  chooserState  
);
    logic [1:0] chooser [255:0];

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            int i;
            for (i = 0; i < 256; i = i + 1)
                chooser[i] <= 2'b10; 
        end else begin
            if (gshareCorrect && !correlatedCorrect && chooser[branchPC[7:0]] != 2'b00)
                chooser[branchPC[7:0]] <= chooser[branchPC[7:0]] - 1;
            else if (!gshareCorrect && correlatedCorrect && chooser[branchPC[7:0]] != 2'b11)
                chooser[branchPC[7:0]] <= chooser[branchPC[7:0]] + 1;
        end
    end

    assign chooserState = chooser[branchPC[7:0]];
endmodule


module gshare_predictor(
    input logic clock, reset,
    input logic [31:0] branch_PC,
    input logic branch_taken,
    output logic predict_taken
);

    logic [7:0] globalBHR; 
    logic [7:0] index;      
    logic       phtPredict; 

    global_history_register ghr (
        .clock(clock),
        .reset(reset),
        .update(branch_taken),
        .taken(branch_taken),
        .globalBHR(globalBHR)
    );

    assign index = branch_PC[7:0] ^ globalBHR;

    pattern_history_table pht (
        .clock(clock),
        .reset(reset),
        .index(index),
        .update(branch_taken),
        .branch_taken(branch_taken),
        .prediction(phtPredict)
    );

    assign predict_taken = phtPredict;    
endmodule


module correlated_predictor (
    input logic clock, reset,
    input logic [31:0] branch_PC,
    input logic branch_taken,
    output logic predict_taken
);

    logic [7:0] branchHistory;  
    logic       phtPredict;    

    branch_history_table bht (
        .clock(clock),
        .reset(reset),
        .branchPC(branch_PC),
        .update(branch_taken),
        .taken(branch_taken),
        .branchHistory(branchHistory)
    );  

    pattern_history_table pht (
        .clock(clock),
        .reset(reset),
        .index(branchHistory),  
        .update(branch_taken),
        .branch_taken(branch_taken),
        .prediction(phtPredict)
    );

    assign predict_taken = phtPredict;  
endmodule


module tournament_predictor (
    input logic clock, reset,
    input logic [31:0] branch_PC,
    input logic branch_taken,
    output logic predict_taken
);

    logic gshare_prediction, correlated_prediction;
    logic gshare_correct, correlated_correct;
    logic [1:0] chooser_state;

    gshare_predictor gshare (
        .clock(clock),
        .reset(reset),
        .branch_PC(branch_PC),
        .branch_taken(branch_taken),
        .predict_taken(gshare_prediction)
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

    chooser_table chooser (
        .clock(clock),
        .reset(reset),
        .branchPC(branch_PC),
        .gshareCorrect(gshare_correct),
        .correlatedCorrect(correlated_correct),
        .chooserState(chooser_state)
    );

    assign predict_taken = (chooser_state >= 2'b10) ? correlated_prediction : gshare_prediction;

endmodule
