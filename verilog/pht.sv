`include "sys_defs.svh"

module pht(
    input  logic        clock, reset,

    // FETCH stage: prediction
    input  logic [7:0]  predict_index,
    output logic        prediction,

    // EXECUTE stage: update
    input  logic        update_enable,
    input  logic [7:0]  update_index,
    input  logic        update_taken
);

    logic [1:0] pht [255:0];

    // Predict from fetch PC
    assign prediction = (pht[predict_index] >= 2'b10);

    // Update from execute PC
    always_ff @(posedge clock) begin
        if (reset) begin
            int i;
            for (i = 0; i < 256; i++)
                pht[i] <= 2'b01; // weakly not taken
        end else if (update_enable) begin
            if (update_taken && pht[update_index] != 2'b11)
                pht[update_index] <= pht[update_index] + 1;
            else if (!update_taken && pht[update_index] != 2'b00)
                pht[update_index] <= pht[update_index] - 1;
        end
    end
endmodule
