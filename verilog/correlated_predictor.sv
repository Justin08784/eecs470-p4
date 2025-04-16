`include "sys_defs.svh"

module correlated_predictor (
    input  logic           clock,
    input  logic           reset,
    
    // Input from fetch stage
    input  fetch2predictor fetch_in,     

    // Output to fetch stage (branch prediction result)
    output predictor2fetch pred_out  

    // Update from retire stage
   // input  retire2predictor retire_in,    // Branch outcome and address update from the retire stage
    //output logic           update_enable, // Enable signal to update the BHT/PHT
    //output logic [1:0]     update_taken,  // Taken/Not-Taken result for each instruction
   // output logic [31:0]    update_PC      // Updated PC from the branch outcome
);

    logic [7:0] bhr0;
    logic [7:0] bhr1;


    logic [7:0] pht_idx0;
    logic [7:0] pht_idx1;

    logic [7:0] update_pht_idx0;
    logic [7:0] update_pht_idx1;


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


    // Compute PHT indices using PC XOR BHR
    assign pht_idx0 = /*fetch_in.PC[0][7:0] ^*/ bhr0;
    assign pht_idx1 = /*fetch_in.PC[1][7:0] ^*/ bhr1;

   // assign update_pht_idx0 = /*fetch_in.correct_PC[0][7:0] ^*/ fetch_in.correlated_bhr[0];
   // assign update_pht_idx1 = /*fetch_in.correct_PC[1][7:0] ^*/ fetch_in.correlated_bhr[1];

    logic [1:0] prediction;




    // === Pattern History Table ===
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

    assign pred_out.prediction[0] = prediction[0];//(bhr0 != 8'b00000000) ? prediction[0] : 1'b0;
    assign pred_out.prediction[1] = prediction[1];//(bhr1 != 8'b00000000) ? prediction[1] : 1'b0;
    assign pred_out.bhr[0] = bhr0;
    assign pred_out.bhr[1] = bhr1;

endmodule
