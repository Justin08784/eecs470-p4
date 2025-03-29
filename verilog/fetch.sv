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

module stage_if_p4 (
    input           clock,          // system clock
    input           reset,          // system reset
    input           flush,
    //input     [1:0] if_valid,       // only go to next PC when true
    input   decode2fetch d_in,
    output  fetch2decode d_out,

    // input           take_branch,    // taken-branch signal
    // input ADDR      branch_target,  // target pc: use if take_branch is TRUE
    input retire2fetch r_in,
    input MEM_BLOCK [1:0] Imem_data,      // data coming back from Instruction memory

    // tags from memory
    // input MEM_TAG  Imem2proc_transaction_tag, // Should be zero unless there is a response
    // input MEM_TAG  Imem2proc_data_tag,

    // output MEM_COMMAND  Imem_command, // Command sent to memory
    //output IF_ID_PACKET [1:0] if_packet,
    // output ADDR         Imem_addr, // address sent to Instruction memory
    output ADDR PC_reg
);

    // ADDR PC_reg; // PCs we are currently fetching
    // MEM_BLOCK icache_out;
    // logic  icache_valid;
    // INST [1:0] fifo_insns;

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

    // logic [$clog2(`N):0] if_valid_q;

    // fifo #(
    //     .DEPTH(16),
    //     .WIDTH($bits(INST)),
    //     .NUM_RPORTS(`N),
    //     .NUM_WPORTS(`N),
    //     .MAX_SCNT(`N)
    // ) dut (
    //     .clock      (clock),
    //     .reset      (reset),
    //     .wr_en_cnt  (free_scnt),
    //     .wr_data    (Imem_data),
    //     .rd_en_cnt  (d_in.d_rdy_cnt),
    //     .rd_data    (fifo_insns),
    //     .free_scnt  (free_scnt),
    //     .used_scnt  (used_scnt)
    // );

    // genvar i;
    // generate
    //     for (i = 0; i < N; i++) begin

    // Keep if valid until it gets valid data out
    // always_ff @(posedge clock) begin
    //     if (reset) begin
    //         if_valid_q <= '0;
    //     end else begin
    //         if_valid_q <= d_in.d_rdy_cnt || (if_valid_q && d_out.f_en_cnt == 0);
    //     end
    // end

    logic [$clog2(`N):0]    free_scnt, used_scnt, f_cnt;
    IF_ID_PACKET [`N-1:0]   f_dat;

    logic off; // 1 if PC is dw-misaligned (i.e. starts at 2nd word of double word)
    always_comb begin
        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);

        f_cnt = free_scnt < `N ? 0 : `N; // no partial fetches (for simplicity)! 

        off = PC_reg[2]; 
        for (int unsigned i = 0, logic vld = 0; i < `N; ++i) begin
            vld = i < f_cnt;
            f_dat[i] = '{
                inst  : vld ? Imem_data[(i + off) / 2].word_level[(i + off) % 2] : `NOP,
                PC    : PC_reg + 4*i,
                NPC   : PC_reg + 4*(i+1),
                valid : vld
            };
        end
    end

    fifo #(
        .DEPTH(4*`N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) dut (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .wr_en_cnt  (f_cnt),
        .wr_data    (f_dat),
        .rd_en_cnt  (d_out.f_en_cnt),
        .rd_data    (d_out.f_dat),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;                // initial PC value is 0 (the memory address where our program starts)
        end else if (flush) begin
            PC_reg <= r_in.corrected_PC;
        end else begin
            PC_reg <= PC_reg + 4*f_cnt; // ...or transition to next PC if valid
        end
    end

    // debugging
    `ifndef SYNTH
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | >> Fetch >>", $time);
            $display("r_in: {flush: %b, corrected_PC: 0x%x}", flush, r_in.corrected_PC);
            $display("PC_reg:  %x", PC_reg);
            $display("Imem_data: %x", Imem_data);
            $display("  %3d | << Fetch <<", $time);
        end
    end
    `endif // SYNTH

    // //RE-EVALUATE
    // // assign valid_out = icache_valid ? (if_valid_q) : '0 && (if_valid_q[0] || if_valid_q[1]);
    // // assign valid_out[1] = icache_valid && if_valid_q[1] && (PC_reg % 8 == 0);

endmodule // stage_if
