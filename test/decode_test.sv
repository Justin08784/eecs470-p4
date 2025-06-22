`timescale 1ns/1ps
`include "sys_defs.svh"
`include "ISA.svh"

module decoder_tb;

    // Parameters
    parameter N = 2; // Example value, adjust as needed

    // Inputs
    logic clock;
    logic reset;
    IF_ID_PACKET [N-1:0] if_id_reg;
    logic [$clog2(N):0] valid;

    // Outputs
    ID_RENAME_PKT [N-1:0] decode_out;
    logic [$clog2(N):0] valid_out;

    // Instantiate the decoder module
    decoder uut (
        .clock(clock),
        .reset(reset),
        .if_id_reg(if_id_reg),
        .valid(valid),
        .decode_out(decode_out),
        .valid_out(valid_out)
    );

    // Clock generation
    always #5 clock = ~clock; // 10ns clock period

    // Test sequence
    initial begin
        $dumpfile("decoder_tb.vcd");
        $dumpvars(0, decoder_tb);

        // Initialize signals
        clock = 0;
        reset = 1;
        valid = 0;
        if_id_reg = '{default: '0};

        // Reset phase
        #10 reset = 0;
        
        // Test Case 1: LUI instruction
        if_id_reg[0].inst = `RV32_LUI;
        if_id_reg[0].PC = 32'h00000000;
        valid = 1;
        #10;

        // Check result
        if (decode_out[0].opa_select != OPA_IS_ZERO || decode_out[0].opb_select != OPB_IS_U_IMM) 
            $display("Test Case 1 Failed: LUI Decoding Incorrect");
        else 
            $display("Test Case 1 Passed");

        // Test Case 2: JAL instruction
        if_id_reg[0].inst = `RV32_JAL;
        if_id_reg[0].PC = 32'h00000004;
        valid = 1;
        #10;

        if (decode_out[0].uncond_branch != `TRUE || decode_out[0].opa_select != OPA_IS_PC || decode_out[0].opb_select != OPB_IS_J_IMM)
            $display("Test Case 2 Failed: JAL Decoding Incorrect");
        else 
            $display("Test Case 2 Passed");

        // Test Case 3: ADD instruction
        if_id_reg[0].inst = `RV32_ADD;
        if_id_reg[0].PC = 32'h00000008;
        valid = 1;
        #10;

        if (decode_out[0].alu_func != ALU_ADD)
            $display("Test Case 3 Failed: ADD Decoding Incorrect");
        else 
            $display("Test Case 3 Passed");

        // Test Case 4: Multiply instruction
        if_id_reg[0].inst = `RV32_MUL;
        valid = 1;
        #10;

        if (decode_out[0].mult != `TRUE)
            $display("Test Case 4 Failed: MUL Decoding Incorrect");
        else 
            $display("Test Case 4 Passed");

        // Test Case 5: Illegal instruction
        if_id_reg[0].inst = 32'hFFFFFFFF; // Random invalid instruction
        valid = 1;
        #10;

        if (decode_out[0].illegal != `TRUE)
            $display("Test Case 5 Failed: Illegal Instruction Decoding Incorrect");
        else 
            $display("Test Case 5 Passed");

        // End simulation
        $finish;
    end

endmodule
