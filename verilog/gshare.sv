`include "sys_defs.svh"


module gshare (
    input  logic              clock,
    input  logic              reset,

    input  fetch2predictor    fetch_2_pred,

    output predictor2fetch     pred_2_fetch
);

    logic [`GSHARE_GBHR_WIDTH-1:0] globalBHR;
    logic [`N-1:0][`GSHARE_PHT_INDEX_WIDTH-1:0] predict_index;
    logic [`N-1:0][`GSHARE_PHT_INDEX_WIDTH-1:0] update_index;

    logic [1:0] prediction;

    global_history_register ghr (
        .clock(clock),
        .reset(reset),
        .fetch_2_pred(fetch_2_pred),
        .globalBHR(globalBHR)
    );

    assign pred_2_fetch.bhr = globalBHR;

    assign predict_index[0] = fetch_2_pred.PC[0][`GSHARE_GBHR_WIDTH-1:0] ^ globalBHR;
    assign predict_index[1] = fetch_2_pred.PC[1][`GSHARE_GBHR_WIDTH-1:0] ^ globalBHR;

    

    assign update_index[0] = fetch_2_pred.correct_PC[0] ^ fetch_2_pred.retired_bhr[0];
    assign update_index[1] = fetch_2_pred.correct_PC[1] ^ fetch_2_pred.retired_bhr[1];


    pht pht0 (
        .clock(clock),
        .reset(reset),

        
        .predict_index0(predict_index[0]),
        .prediction0(prediction[0]),
        .predict_index1(predict_index[1]),
        .prediction1(prediction[1]),

    
        .update_enable0(fetch_2_pred.update_enable[0]),
        .update_index0(update_index[0]),
        .update_taken0(fetch_2_pred.taken[0]),

        .update_enable1(fetch_2_pred.update_enable[1]),
        .update_index1(update_index[1]),
        .update_taken1(fetch_2_pred.taken[1])
    );


    assign pred_2_fetch.prediction[0] = prediction[0];
    assign pred_2_fetch.prediction[1] = prediction[1];


     always_ff @(posedge clock) begin
        `ifdef DEBUG
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
        `endif
    end

endmodule
