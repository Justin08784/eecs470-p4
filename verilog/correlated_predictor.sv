`include "sys_defs.svh"

module correlated_predictor (
    input  logic           clock,
    input  logic           reset,
    

    input  fetch2predictor fetch_in,     

    output predictor2fetch pred_out  

);

    logic [`CORR_BHR_WIDTH-1:0] bhr0;
    logic [`CORR_BHR_WIDTH-1:0] bhr1;


    logic [`CORR_BHR_WIDTH-1:0] pht_idx0;
    logic [`CORR_BHR_WIDTH-1:0] pht_idx1;

    logic [`CORR_BHR_WIDTH-1:0] update_pht_idx0;
    logic [`CORR_BHR_WIDTH-1:0] update_pht_idx1;


   branch_history_table bhr_table (
    .clock(clock),
    .reset(reset),
    .fetch_PC0(fetch_in.PC[0]),
    .fetch_PC1(fetch_in.PC[1]),


    .update_enable0(fetch_in.update_enable[0]),
    .update_enable1(fetch_in.update_enable[1]),

    .update_PC0(fetch_in.correct_PC[0][7:0]),
    .update_PC1(fetch_in.correct_PC[1][7:0]),

    .taken0(fetch_in.taken[0]),
    .taken1(fetch_in.taken[1]),

    .bhr0(bhr0),
    .bhr1(bhr1),

    .table_index0(update_pht_idx0),
    .table_index1(update_pht_idx1)
);


    assign pht_idx0 = bhr0;
    assign pht_idx1 = bhr1;


    logic [1:0] prediction;

    pht pht_inst (
        .clock(clock),
        .reset(reset),

        .predict_index0(pht_idx0),
        .prediction0(prediction[0]),
        .predict_index1(pht_idx1),
        .prediction1(prediction[1]),

        .update_enable0(fetch_in.update_enable[0]),
        .update_index0(update_pht_idx0),
        .update_taken0(fetch_in.taken[0]),

        .update_enable1(fetch_in.update_enable[1]),
        .update_index1(update_pht_idx1),
        .update_taken1(fetch_in.taken[1])
    );

    assign pred_out.prediction[0] = prediction[0];
    assign pred_out.prediction[1] = prediction[1];
    assign pred_out.bhr[0] = bhr0;
    assign pred_out.bhr[1] = bhr1;

endmodule
