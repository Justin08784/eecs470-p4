`include "sys_defs.svh"

module tournament_predictor (
    input  logic              clock,
    input  logic              reset,

    input  fetch2predictor    fetch_in,
    //input  retire2predictor   retire_in,

    output predictor2fetch    pred_out
);

    // === Internal signals ===

    // Correlated predictor interface
    logic [1:0] corr_pred;
    logic [1:0] [7:0] corr_bhr;

    // Gshare predictor interface
    logic [1:0] gshare_pred;

    // Chooser table: 2-bit counters per PC[7:0]
    logic [255:0][1:0] chooser_table;
    logic [7:0] fetch_index0, fetch_index1;
    logic [7:0] retire_index0, retire_index1;

    assign fetch_index0  = fetch_in.PC[0][7:0];
    assign fetch_index1  = fetch_in.PC[1][7:0];
    assign retire_index0 = /*retire_in*/fetch_in.correct_PC[0][7:0];
    assign retire_index1 = /*retire_in*/fetch_in.correct_PC[1][7:0];

    // === Gshare Predictor ===
    gshare gshare_inst (
        .clock(clock),
        .reset(reset),
        .fetch_2_pred(fetch_in),
        .pred_2_fetch(pred_out_gshare)
    );

    // === Correlated Predictor ===
    correlated_predictor correlated_inst (
        .clock(clock),
        .reset(reset),
        .fetch_in(fetch_in),
        //.retire_in(retire_in),
        .pred_out(corr_pred)
    );

    // === Select prediction based on chooser ===
    always_comb begin
        for (int i = 0; i < 2; i++) begin
            case (chooser_table[fetch_in.PC[i][7:0]])
                2'b00, 2'b01: pred_out.prediction[i] = gshare_pred[i];       // favor gshare
                2'b10, 2'b11: pred_out.prediction[i] = corr_pred[i];         // favor correlated
            endcase
        end
       // pred_out.bhr[0] = corr_bhr[0]; // optional — if fetch stage needs it
       // pred_out.bhr[1] = corr_bhr[1];
    end

    logic g_correct, c_correct;
    logic [7:0] idx;

    // === Update chooser table on retirement ===
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            for (int i = 0; i < 256; i++) begin
                chooser_table[i] <= 2'b01; 
            end
        end else begin
            for (int i = 0; i < 2; i++) begin
                g_correct = (gshare_pred[i] == fetch_in.taken[i]);
                c_correct = (corr_pred[i] == fetch_in.taken[i]);
                idx = fetch_in.correct_PC[i][7:0];

                // Only update chooser if one was right and one was wrong
                if (g_correct && !c_correct && chooser_table[idx] != 2'b00)
                    chooser_table[idx] <= chooser_table[idx] - 1;
                else if (!g_correct && c_correct && chooser_table[idx] != 2'b11)
                    chooser_table[idx] <= chooser_table[idx] + 1;
            end
        end
    end

endmodule
