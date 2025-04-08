`include "sys_defs.svh"


module gshare (
    input  logic              clock,
    input  logic              reset,

    input  fetch2predictor    fetch_2_pred,
    input  retire2predictor   ret_2_pred,

    output logic [`N-1:0]     predict_taken
);

    logic [7:0] globalBHR;
    logic [7:0] predict_index [`N-1:0];
    logic [7:0] update_index  [`N-1:0];
    logic [7:0] bhr_at_fetch0, bhr_at_fetch1;
    logic [31:0] deq_PC0, deq_PC1;
    logic buffer_ready0, buffer_ready1;
    logic [1:0] prediction;

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

        // Enqueue predictions
        .enq_valid0(1'b1),
        .enq_PC0(fetch_2_pred.PC[0]),
        .enq_bhr0(globalBHR),

        .enq_valid1(1'b1),
        .enq_PC1(fetch_2_pred.PC[1]),
        .enq_bhr1(globalBHR),

        // Dequeue for update
        .deq_valid0(ret_2_pred.update_enable[0]),
        .deq_PC0(deq_PC0),
        .deq_bhr0(bhr_at_fetch0),

        .deq_valid1(ret_2_pred.update_enable[1]),
        .deq_PC1(deq_PC1),
        .deq_bhr1(bhr_at_fetch1),

        .buffer_ready0(buffer_ready0),
        .buffer_ready1(buffer_ready1),
        .buffer_full()
    );

    // === Prediction indices
    assign predict_index[0] = fetch_2_pred.PC[0][7:0] ^ globalBHR;
    assign predict_index[1] = fetch_2_pred.PC[1][7:0] ^ globalBHR;

    assign update_index[0] = deq_PC0[7:0] ^ bhr_at_fetch0;
    assign update_index[1] = deq_PC1[7:0] ^ bhr_at_fetch1;

    /*always_comb begin
        $display("  GLOBAL BHR = %8b", globalBHR);
        $display("  predict_taken[0] = %1b", predict_taken[0]);
        $display("  predict_taken[1] = %1b", predict_taken[1]);
        $display("  predict_index[0] = %8b", predict_index[0]);
        $display("  predict_index[1] = %8b", predict_index[1]);
        $display("  prediction[0] = %1b", prediction[0]);
        $display("  prediction[1] = %1b", prediction[1]);

        $display("  ret_2_pred.taken[0] = %1b", ret_2_pred.taken[0]);
        $display("  ret_2_pred.taken[1] = %1b", ret_2_pred.taken[1]);
      //  ret_2_pred.taken[0]
        //ret_2_pred.taken[0]

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
        .update_enable0(ret_2_pred.update_enable[0] && buffer_ready0),
        .update_index0(update_index[0]),
        .update_taken0(ret_2_pred.taken[0]),

        .update_enable1(ret_2_pred.update_enable[1] && buffer_ready1),
        .update_index1(update_index[1]),
        .update_taken1(ret_2_pred.taken[1])
    );


    assign predict_taken[0] = prediction[0];
    assign predict_taken[1] = prediction[1];

    always_ff @(posedge clock) begin
        $display("DEQ_PC0 = 0x%h  DEQ_PC1 = 0x%h", deq_PC0, deq_PC1);
        $display("BHR_AT_FETCH0 = %b  BHR_AT_FETCH1 = %b", bhr_at_fetch0, bhr_at_fetch1);
        $display("update_index0 = %b  update_index1 = %b", update_index[0], update_index[1]);
        $display("buffer_ready0 = %b  buffer_ready1 = %b", buffer_ready0, buffer_ready1);
        $display("  prediction[0] = %1b", prediction[0]);
        $display("  prediction[1] = %1b", prediction[1]);
    end



endmodule
