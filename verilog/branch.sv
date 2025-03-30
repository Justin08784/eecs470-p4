`include "sys_defs.svh"


module global_history_register(
    input logic clock, reset,

    input retire2predictor ret_2_pred,

    //input 
    //input logic update,
    //input logic taken,

    output logic [3:0] globalBHR
    
    always_ff @(posedge clock) begin
            if (reset) begin 
                globalBHR <= 8'b0; 
            else if (update_enable)
                globalBHR <= {globalBHR[6:0], ret_2_pred.taken}; 
            end
    end
);

endmodule

module pht(
    input logic clock, reset,
    input logic [7:0] index,
    input retire2predictor ret_2_pred,
   // input logic update,
    //input logic branch_taken,
    //output logic prediction


    output logic prediction
);


    prediction = (pht[index] == 2'b00 || pht[index] == 2'b01) ? 1'b0 : 1'b1;  

    logic [255:0][1:0] pht; 

    always_ff @(posedge clock) begin
        if (reset) begin
            int i;
            for (i = 0; i < 256; i = i + 1)
                pht[i] <= 2'b01; 
        end else if (update_enable) begin 
            if (ret_2_pred.taken && pht[index] != 2'b11)
                pht[index] <= pht[index] + 1;
            else if (!ret_2_pred && pht[index] != 2'b00)
                pht[index] <= pht[index] - 1;
        end


    end

    
    assign prediction = (pht[index] >= 2'b10);

endmodule




module gshare_predictor (
    input  logic              clock,
    input  logic              reset,


    input  fetch2predictor    fetch_2_pred,

    // Execute stage
    input  retire2predictor  ret_2_pred,

    // Output prediction to fetch stage
    output logic [`N-1:0]     predict_taken
);

    logic [7:0] globalBHR;
    logic [7:0] predict_index;
    logic [7:0] update_index;
    logic       prediction;
    logic [7:0] bhr_at_fetch;
    logic       buffer_ready;

    // === Global History Register ===
    global_history_register ghr (
        .clock(clock),
        .reset(reset),
        .ret_2_pred(ret_2_pred),
        .globalBHR(globalBHR)
    );

    // === Prediction Buffer ===
    prediction_buffer pred_buf (
        .clock(clock),
        .reset(reset),
        .enq_valid(1'b1),
        .enq_PC(fetch_2_pred.PC[0]),
        .enq_bhr(globalBHR),

        .deq_valid(1'b1),              // advance on every update
        .deq_PC(ret_2_pred.PC),
        .deq_bhr(bhr_at_fetch),
        .deq_ready(buffer_ready)
    );

    // === Index Computation ===
    assign predict_index = fetch_2_pred.PC[0][7:0] ^ globalBHR;
    assign update_index  = ret_2_pred.PC[7:0] ^ bhr_at_fetch;

    // === Pattern History Table ===
    pattern_history_table pht (
        .clock(clock),
        .reset(reset),
        .predict_index(predict_index),
        .prediction(prediction),
        .update_enable(1'b1),  // or make it conditional on branch resolution
        .update_index(update_index),
        .update_taken(ex_2_pred.taken)
    );

    assign predict_taken[0] = prediction;

endmodule

