/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_if.sv                                         //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module stage_if (
    input           clock,          // system clock
    input           reset,          // system reset
    input           [1:0] if_valid,       // only go to next PC when true
    input           take_branch,    // taken-branch signal
    input ADDR      branch_target,  // target pc: use if take_branch is TRUE
    input MEM_BLOCK Imem_data,      // data coming back from Instruction memory

    // tags from memory
    input MEM_TAG  Imem2proc_transaction_tag, // Should be zero unless there is a response
    input MEM_TAG  Imem2proc_data_tag,

    output MEM_COMMAND  Imem_command, // Command sent to memory
    output IF_ID_PACKET [1:0] if_packet,
    output ADDR         Imem_addr // address sent to Instruction memory
);

    ADDR PC_reg; // PCs we are currently fetching
    MEM_BLOCK icache_out;
    logic  icache_valid;

    logic [1:0] valid_out;

    icache icache_0 (
        // inputs
        .clock                      (clock),
        .reset                      (reset),
        .Imem2proc_transaction_tag  (Imem2proc_transaction_tag),
        .Imem2proc_data             (Imem_data),
        .Imem2proc_data_tag         (Imem2proc_data_tag),
        .proc2Icache_addr           (PC_reg),
        // outputs
        .proc2Imem_command          (Imem_command),
        .proc2Imem_addr             (Imem_addr),
        .Icache_data_out            (icache_out), // Data is mem[proc2Icache_addr]
        .Icache_valid_out           (icache_valid) // When valid is high
    );

    logic [1:0] if_valid_q;

    // genvar i;
    // generate
    //     for (i = 0; i < N; i++) begin
    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;             // initial PC value is 0 (the memory address where our program starts)
        end else if (take_branch) begin
            PC_reg <= branch_target; // update to a taken branch (does not depend on valid bit)
        end else if (valid_out) begin
            PC_reg <= PC_reg + 4;    // or transition to next PC if valid
        end
    end

    // Keep if valid until it gets valid data out
    always_ff @(posedge clock) begin
        if (reset) begin
            if_valid_q[0] <= 1'b0;
            if_valid_q[1] <= 1'b0;
        end else begin
            if_valid_q[0] <= if_valid[0] || (if_valid_q[0] && !valid_out);
            if_valid_q[1] <= if_valid[1] || (if_valid_q[1] && !valid_out);
        end
    end

    assign valid_out[0] = icache_valid && if_valid_q[0];
    assign valid_out[1] = icache_valid && if_valid_q[1] && (PC_reg % 8 == 0);

    // index into the word (32-bits) of memory that matches this instruction
    // FOR SUPERSCALAR: take ENTIRE BLOCK instead of pulling based on PC_reg % 8
    assign if_packet[0].inst = valid_out[0] ? icache_out.word_level[PC_reg[2]] : `NOP;
    assign if_packet[1].inst = valid_out[1] ? icache_out.word_level[~PC_reg[2]] : `NOP;

    assign if_packet[0].PC  = PC_reg;
    assign if_packet[0].NPC = PC_reg + 4; // pass PC+4 down pipeline w/instruction
    assign if_packet[1].PC  = PC_reg + 4;
    assign if_packet[1].NPC = PC_reg + 8; // pass PC+4 down pipeline w/instruction

    assign if_packet[0].valid = valid_out[0];
    assign if_packet[1].valid = valid_out[1];
    //     end
    // endgenerate

endmodule // stage_if
