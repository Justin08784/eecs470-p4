// Fetch module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh
`include "sys_defs.svh"



module fetch_test();

    logic              clock, reset;
    logic        [1:0] if_valid;
    logic              take_branch;
    ADDR               branch_target;
    MEM_BLOCK    [1:0] Imem_data;
    MEM_TAG      [1:0] Imem2proc_transaction_tag, Imem2proc_data_tag;
    MEM_COMMAND  [1:0] Imem_command;
    IF_ID_PACKET [1:0] if_packet;
    ADDR         [1:0] Imem_addr;

    // INSTANCE is from the sys_defs.svh file
    // it renames the module if SYNTH is defined in
    // order to rename the module to FIFO_svsim
    stage_if dut (
        .clock    (clock),
        .reset    (reset),
        .if_valid (if_valid),
        .take_branch(take_branch),
        .branch_target(branch_target),
        .Imem_data(Imem_data),
        .Imem2proc_transaction_tag(Imem2proc_transaction_tag),
        .Imem2proc_data_tag(Imem2proc_data_tag),
        .Imem_command(Imem_command),
        .if_packet(if_packet),
        .Imem_addr(Imem_addr)
    );
    

    // bind dut rob_sva #(
    //     .DEPTH(`DEPTH),
    //     .WIDTH(`WIDTH)
    // ) DUT_sva (
    //     .clock    (clock),
    //     .reset    (reset)
    //     // .wr_en (wr_en),
    //     // .rd_en (rd_en),
    //     // .err      (err),
    //     // .wr_data (wr_data),
    //     // .wr_valid (wr_valid),
    //     // .rd_valid (rd_valid),
    //     // .rd_data  (rd_data),
    //     // .spots    (spots),
    //     // .full     (full)
    // );

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    // Generate random numbers for our write data on each cycle
    always @(negedge clock) begin
        std::randomize(Imem_data);
    end

    initial begin

        $dumpfile("../ROB.vcd");
        $dumpvars(0, rob_test.dut);
        $display("\nStart Testbench");

        clock = 1;
        reset = 1;
        if_valid = 2'b00;
        take_branch = 0;
        branch_target = 0;
        Imem2proc_data_tag = 0;
        Imem2proc_transaction_tag = 0;

        $monitor("  %3d | branch?: %b  target: %d  |  mem_data: %h  data_tag: %h  trans_tag: %h | inst_out: %h  PC_out: %d  valid:%b",
                  $time,  take_branch, branch_target, Imem_data, Imem2proc_data_tag, Imem2proc_transaction_tag, if_packet.inst, if_packet.PC, if_packet.valid);

        @(negedge clock);
        @(negedge clock);
        reset = 0;

        // ---------- Test 1 ---------- //
        if_valid = 2'b01;
        @(negedge clock);
        if_valid = 2'b00;

        // ---------- Test 2 ---------- //
        if_valid = 2'b11;
        @(negedge clock);

        // ---------- Test 3 ---------- //
        take_branch = 1;
        branch_target = 528;
        @(negedge clock);

        // ---------- Test 4 ---------- //
        branch_target = 0;
        @(negedge clock);
        take_branch = 0;

        $finish;
    end

endmodule
