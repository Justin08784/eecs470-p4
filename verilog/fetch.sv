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
    //input     [1:0] if_valid,       // only go to next PC when true
    input decode2fetch fetch_in,
    input           take_branch,    // taken-branch signal
    input ADDR      branch_target,  // target pc: use if take_branch is TRUE
    input MEM_BLOCK [1:0] Imem_data,      // data coming back from Instruction memory

    // tags from memory
    // input MEM_TAG  Imem2proc_transaction_tag, // Should be zero unless there is a response
    // input MEM_TAG  Imem2proc_data_tag,

    // output MEM_COMMAND  Imem_command, // Command sent to memory
    //output IF_ID_PACKET [1:0] if_packet,
    // output ADDR         Imem_addr, // address sent to Instruction memory
    output fetch2decode fetch_out,
    output ADDR PC_reg,
    output ADDR PC_reg4
);

    //ADDR PC_reg; // PCs we are currently fetching
    MEM_BLOCK icache_out;
    logic  icache_valid;
    INST [1:0] fifo_insns;
    logic [$clog2(`N):0] free_scnt, used_scnt;

    //logic [1:0] valid_out;

    // icache icache_0 (
    //     // inputs
    //     .clock                      (clock),
    //     .reset                      (reset),
    //     .Imem2proc_transaction_tag  (Imem2proc_transaction_tag),
    //     .Imem2proc_data             (Imem_data),
    //     .Imem2proc_data_tag         (Imem2proc_data_tag),
    //     .proc2Icache_addr           (PC_reg),
    //     // outputs
    //     .proc2Imem_command          (Imem_command),
    //     .proc2Imem_addr             (Imem_addr),
    //     .Icache_data_out            (icache_out), // Data is mem[proc2Icache_addr]
    //     .Icache_valid_out           (icache_valid) // When valid is high
    // );

    logic [$clog2(`N):0] if_valid_q;

    fifo #(
        .DEPTH(16),
        .WIDTH($bits(INST)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .MAX_SCNT(`N)
    ) dut (
        .clock      (clock),
        .reset      (reset),
        .wr_en_cnt  (free_scnt),
        .wr_data    (Imem_data),
        .rd_en_cnt  (fetch_in.d_rdy_cnt),
        .rd_data    (fifo_insns),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    // genvar i;
    // generate
    //     for (i = 0; i < N; i++) begin

    // Keep if valid until it gets valid data out
    // always_ff @(posedge clock) begin
    //     if (reset) begin
    //         if_valid_q <= '0;
    //     end else begin
    //         if_valid_q <= fetch_in.d_rdy_cnt || (if_valid_q && fetch_out.f_en_cnt == 0);
    //     end
    // end

    //RE-EVALUATE
    always_comb begin
        //if (icache_valid) begin
            if (if_valid_q == 2 && PC_reg % 8 != 0) begin
                fetch_out.f_en_cnt = 2'b01;
            end else begin
                fetch_out.f_en_cnt = fetch_in.d_rdy_cnt;
            end
        //end else begin
        //    fetch_out.f_en_cnt = 2'b00;
        //end
    end
    // assign valid_out = icache_valid ? (if_valid_q) : '0 && (if_valid_q[0] || if_valid_q[1]);
    // assign valid_out[1] = icache_valid && if_valid_q[1] && (PC_reg % 8 == 0);

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;             // initial PC value is 0 (the memory address where our program starts)
            PC_reg4 <= 4;
        end else if (take_branch) begin
            PC_reg <= branch_target; // update to a taken branch (does not depend on valid bit)
            PC_reg4 <= branch_target + 4;
        end else if (|fetch_out.f_en_cnt) begin
            PC_reg <= PC_reg + (fetch_out.f_en_cnt * 4);    // or transition to next PC if valid
            PC_reg4 <= PC_reg4 + (fetch_out.f_en_cnt * 4);
        end
    end

    // index into the word (32-bits) of memory that matches this instruction
    // FOR SUPERSCALAR: take ENTIRE BLOCK instead of pulling based on PC_reg % 8
    assign fetch_out.f_dat[0].inst = (fetch_out.f_en_cnt != 0) ? fifo_insns[0] : `NOP;
    assign fetch_out.f_dat[1].inst = (fetch_out.f_en_cnt == 2) ? fifo_insns[1] : `NOP;

    assign fetch_out.f_dat[0].PC  = PC_reg;
    assign fetch_out.f_dat[0].NPC = PC_reg + 4; // pass PC+4 down pipeline w/instruction
    assign fetch_out.f_dat[1].PC  = PC_reg4;
    assign fetch_out.f_dat[1].NPC = PC_reg4 + 4; // pass PC+4 down pipeline w/instruction

    assign fetch_out.f_dat[0].valid = |fetch_out.f_en_cnt;
    assign fetch_out.f_dat[1].valid = fetch_out.f_en_cnt == 2;
    //     end
    // endgenerate

endmodule // stage_if
