`timescale 1ns/1ps
`include "branch.sv"

module branch_ testbench;
    logic clock, reset;
    logic [31:0] branch_PC;
    logic branch_taken;
    logic predict_taken;

    tournament_predictor uut (
        .clock(clock),
        .reset(reset),
        .branch_PC(branch_PC),
        .branch_taken(branch_taken),
        .predict_taken(predict_taken)
    );

    // Clock generation
    always #5 clock = ~clock;  // 10ns clock period

    initial begin
        // Initialize signals
        clock = 0;
        reset = 1;
        branch_PC = 32'h00000000;
        branch_taken = 0;
        
        // Apply reset
        #10 reset = 0;

        // Test Case 1: First branch at PC 0x04, not taken
        #10 branch_PC = 32'h00000004; branch_taken = 0;
        #10 $display("PC: %h | Branch Taken: %b | Predicted: %b", branch_PC, branch_taken, predict_taken);

        // Test Case 2: Branch at PC 0x08, taken
        #10 branch_PC = 32'h00000008; branch_taken = 1;
        #10 $display("PC: %h | Branch Taken: %b | Predicted: %b", branch_PC, branch_taken, predict_taken);

        // Test Case 3: Branch at PC 0x0C, not taken
        #10 branch_PC = 32'h0000000C; branch_taken = 0;
        #10 $display("PC: %h | Branch Taken: %b | Predicted: %b", branch_PC, branch_taken, predict_taken);

        // Test Case 4: Branch at PC 0x10, taken
        #10 branch_PC = 32'h00000010; branch_taken = 1;
        #10 $display("PC: %h | Branch Taken: %b | Predicted: %b", branch_PC, branch_taken, predict_taken);

        // Run additional random cases
        repeat (10) begin
            #10 branch_PC = $random;
                branch_taken = $random % 2;
            #10 $display("PC: %h | Branch Taken: %b | Predicted: %b", branch_PC, branch_taken, predict_taken);
        end

        // End simulation
        #50 $finish;
    end
endmodule
