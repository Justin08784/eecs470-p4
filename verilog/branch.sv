`include "sys_defs.svh"


module branch_history_table(
    input logic clock, reset,
    input  ADDR branchPC,
    input logic update,
    input logic taken,
    output [7:0] logic branch_history
);

    logic [255:0][7:0] bht;

    always_ff @(posedge clock) begin
        if (reset) begin
            int i;
            for (i = 0; i < 256; i = i + 1)
                bht[i] <= 8'b0;
        end else begin
            bht[branchPC[7:0]] <= {bht[branchPC[7:1]], taken};
            
        end
    end

    assign branch_history = bht[branchPC[7:0]];

endmodule

module global_history_register(
    input logic clock, reset,

    input execute2predictor ex_2_pred,

    //input 
    //input logic update,
    //input logic taken,
    output logic [3:0] globalBH
    always_ff @(posedge clock) begin
            if (reset) begin 
                globalBHR <= 8'b0; 
            else if (update)
                globalBHR <= {globalBHR[6:0], taken}; 
            end
    end
);

endmodule

module pattern_history_table(
    input logic clock, reset,
    input logic [] index,
    input logic update,
    input logic branch_taken,
    output logic prediction
);

    logic [1:0] pht [255:0]; 

    always_ff @(posedge clock) begin
        if (reset) begin
            int i;
            for (i = 0; i < 256; i = i + 1)
                pht[i] <= 2'b01; 
        end else if (update) begin
           
            if (branch_taken && pht[index] != 2'b11)
                pht[index] <= pht[index] + 1;
            else if (!branch_taken && pht[index] != 2'b00)
                pht[index] <= pht[index] - 1;
        end
    end

    
    assign prediction = (pht[index] >= 2'b10);



endmodule


module chooser_table(
    input  logic        clock, reset,
    input  logic [31:0] branchPC,
    input  logic        gshareCorrect,  
    input  logic        correlatedCorrect,
    output logic [1:0]  chooserState  
);
    logic [255:0] [1:0] chooser;

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
    //input logic [31:0] branch_PC,

    input fetch2predictor fetch_2_pred,
    input execute2predictor ex_2_pred,

    //input logic branch_taken,
    //predictor2fetch pred_2_fetch
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

    input fetch2predictor fetch_2_pred,
    input execute2predictor ex_2_pred,
    //input logic [31:0] branch_PC,
    //input logic branch_taken,
    output logic predict_taken

   // output predictor2fetch pred_2_fetch
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
  //  input logic [31:0] branch_PC,
  //  input logic branch_taken,
    input fetch2predictor fetch_2_pred,
    input execute2predictor ex_2_pred,

   // input update_enable,

    //output logic predict_taken

    output predictor2fetch pred_2_fetch
);

    logic gshare_prediction, correlated_prediction;
    logic gshare_correct, correlated_correct;
    logic [1:0] chooser_state;

    gshare_predictor gshare (
        .clock(clock),
        .reset(reset),

        .fetch_2_pred(fetch_2_pred),
        .ex_2_pred(ex_2_pred),

        .predict_taken(gshare_prediction)
        

        /*.branch_PC(fetch_2_pred.PC),
        .branch_taken(branch_taken),
        .predict_taken(gshare_prediction)*/
    );

    correlated_predictor correlated(
        .clock(clock),
        .reset(reset),

        .fetch_2_pred(fetch_2_pred),
        .ex_2_pred(ex_2_pred),

        //.branch_PC(branch_PC),
        //.branch_taken(branch_taken),
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
