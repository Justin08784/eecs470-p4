`include "sys_defs.svh"


module gshare (
    input  logic              clock,
    input  logic              reset,

    input  fetch2predictor    fetch_2_pred,
    //input  retire2predictor   fetch_2_pred,

    output predictor2fetch     pred_2_fetch
);

    logic [7:0] globalBHR;
    logic [`N-1:0][7:0] predict_index;
    logic [`N-1:0][7:0] update_index;
    logic [7:0] bhr_at_fetch0, bhr_at_fetch1;
    logic [31:0] deq_PC0, deq_PC1;
    logic buffer_ready0, buffer_ready1;
    logic [1:0] prediction;

    // === Global History Register ===
    global_history_register ghr (
        .clock(clock),
        .reset(reset),
        .fetch_2_pred(fetch_2_pred),
        .globalBHR(globalBHR)
    );

    // === Prediction Buffer ===
   /* prediction_buffer pred_buf (
        .clock(clock),
        .reset(reset),

        // Enqueue predictions
        .enq_valid0(1'b1),
        .enq_PC0(fetch_2_pred.PC[0]),
        .enq_bhr0(globalBHR),

        .enq_valid1(1'b1),
        .enq_PC1(fetch_2_pred.PC[1]),
        .enq_bhr1(globalBHR),

        // Dequeue for update
        .deq_valid0(fetch_2_pred.update_enable[0]),
        .deq_PC0(deq_PC0),
        .deq_bhr0(bhr_at_fetch0),

        .deq_valid1(fetch_2_pred.update_enable[1]),
        .deq_PC1(deq_PC1),
        .deq_bhr1(bhr_at_fetch1),

        .buffer_ready0(buffer_ready0),
        .buffer_ready1(buffer_ready1),
        .buffer_full()
    ); */

    assign pred_2_fetch.bhr = globalBHR;

    // === Prediction indices
    assign predict_index[0] = fetch_2_pred.PC[0][7:0] ^ globalBHR;
    assign predict_index[1] = fetch_2_pred.PC[1][7:0] ^ globalBHR;

    

    //DEQ PC NEEDS TO BE CHANGED-- use update enable

    //always_comb begin

    assign update_index[0] = fetch_2_pred.correct_PC[0] ^ fetch_2_pred.retired_bhr[0];
    assign update_index[1] = fetch_2_pred.correct_PC[1] ^ fetch_2_pred.retired_bhr[1];
    //end
    /*always_comb begin
        $display("  GLOBAL BHR = %8b", globalBHR);
        $display("  predict_taken[0] = %1b", predict_taken[0]);
        $display("  predict_taken[1] = %1b", predict_taken[1]);
        $display("  predict_index[0] = %8b", predict_index[0]);
        $display("  predict_index[1] = %8b", predict_index[1]);
        $display("  prediction[0] = %1b", prediction[0]);
        $display("  prediction[1] = %1b", prediction[1]);

        $display("  fetch_2_pred.taken[0] = %1b", fetch_2_pred.taken[0]);
        $display("  fetch_2_pred.taken[1] = %1b", fetch_2_pred.taken[1]);
      //  fetch_2_pred.taken[0]
        //fetch_2_pred.taken[0]

    end*/

    // === Pattern History Table (2-wide)
    pht pht0 (
        .clock(clock),
        .reset(reset),

        // Predictions
        .predict_index0(predict_index[0]),
        .prediction0(prediction[0]),
        .predict_index1(predict_index[1]),
        .prediction1(prediction[1]),

        // Updates
        .update_enable0(fetch_2_pred.update_enable[0] /*&& buffer_ready0*/),
        .update_index0(update_index[0]),
        .update_taken0(fetch_2_pred.taken[0]),

        .update_enable1(fetch_2_pred.update_enable[1] /*&& buffer_ready1*/),
        .update_index1(update_index[1]),
        .update_taken1(fetch_2_pred.taken[1])
    );


    assign pred_2_fetch.prediction[0] = prediction[0];
    assign pred_2_fetch.prediction[1] = prediction[1];

endmodule
