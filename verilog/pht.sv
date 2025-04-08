`include "sys_defs.svh"


module pht (
    input  logic        clock,
    input  logic        reset,

    // Prediction inputs
    input  logic [7:0]  predict_index0,
    input  logic [7:0]  predict_index1,
    output logic        prediction0,
    output logic        prediction1,

    // Update for branch 0
    input  logic        update_enable0,
    input  logic [7:0]  update_index0,
    input  logic        update_taken0,

    // Update for branch 1
    input  logic        update_enable1,
    input  logic [7:0]  update_index1,
    input  logic        update_taken1
);

    logic [255:0][1:0] pht;  // 2-bit saturating counters

    // === Combinational predictions ===
    assign prediction0 = (pht[predict_index0] >= 2'b10);
    assign prediction1 = (pht[predict_index1] >= 2'b10);

    integer i;
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 256; i++) begin
                pht[i] <= 2'b01;  // weakly not taken
            end
        end else begin
            // === Update 0
            if (update_enable0) begin
                if (update_taken0 && pht[update_index0] != 2'b11)
                    pht[update_index0] <= pht[update_index0] + 1;
                else if (!update_taken0 && pht[update_index0] != 2'b00)
                    pht[update_index0] <= pht[update_index0] - 1;
            end

            // === Update 1
            if (update_enable1) begin
                if (update_taken1 && pht[update_index1] != 2'b11)
                    pht[update_index1] <= pht[update_index1] + 1;
                else if (!update_taken1 && pht[update_index1] != 2'b00)
                    pht[update_index1] <= pht[update_index1] - 1;
            end
        end
        $display("  pht[update_index0] = %2b", pht[update_index0]);
        $display("  pht[update_index1] = %2b", pht[update_index1]);

        $display("  pht[predict_index0] = %2b", pht[predict_index0]);
        $display("  pht[predict_index1] = %2b", pht[predict_index1]);
    end

endmodule
