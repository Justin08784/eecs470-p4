`include "sys_defs.svh"


module gshare(
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

    global_history_register ghr (
        .clock(clock),
        .reset(reset),
        .ret_2_pred(ret_2_pred),
        .globalBHR(globalBHR)
    );

    prediction_buffer pred_buf (
        .clock(clock),
        .reset(reset),
        .enq_valid(1'b1),
        .enq_PC(fetch_2_pred.PC[0]),
        .enq_bhr(globalBHR),

        .deq_valid(1'b1),              // advance on every update
        .deq_PC(ret_2_pred.PC[0]),
        .deq_bhr(bhr_at_fetch),
        .deq_ready(buffer_ready)
    );


    
    assign predict_index = fetch_2_pred.PC[0][7:0] ^ globalBHR;
    assign update_index  = ret_2_pred.PC[0][7:0] ^ bhr_at_fetch;


    always_comb begin
         $display("PREDICT INDEX: %b", predict_index);
         $display("GLOBAL BHR: %b", globalBHR);
         $display("UPDATE INDEX: %b", update_index);
         $display("BHR AT FETCH: %b", bhr_at_fetch);
    end


    pht pht0 (
        .clock(clock),
        .reset(reset),
        .predict_index(predict_index),
        .prediction(prediction),
        .update_enable(1'b1),  // or make it conditional on branch resolution
        .update_index(update_index),
        .update_taken(ret_2_pred.taken[0])
    );

    assign predict_taken[0] = prediction;

endmodule

