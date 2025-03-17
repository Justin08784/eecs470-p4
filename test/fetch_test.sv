// Fetch module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh
`include "sys_defs.svh"



module fetch_test();

    logic              clock, reset, valid1, valid2;
    decode2fetch       fetch_in;
    logic        [1:0] Imem_command;
    logic              take_branch;
    ADDR               branch_target, pc1, pc2, PC_reg;
    MEM_BLOCK          Imem_data;
    MEM_TAG            Imem2proc_transaction_tag, Imem2proc_data_tag;
    fetch2decode       fetch_out;
    ADDR               Imem_addr;
    INST               inst1, inst2;

    // INSTANCE is from the sys_defs.svh file
    // it renames the module if SYNTH is defined in
    // order to rename the module to FIFO_svsim
    
    mem memory (
        .clock(clock),
        .proc2mem_addr(Imem_addr), //Imem_addr from fetch (investigate later)
        .proc2mem_data(64'b0), //not relevant
        .proc2mem_command(MEM_LOAD), //MEM_LOAD
        .mem2proc_transaction_tag(Imem2proc_transaction_tag),
        .mem2proc_data(Imem_data),
        .mem2proc_data_tag(Imem2proc_data_tag)
    );

    stage_if dut (
        .clock    (clock),
        .reset    (reset),
        .fetch_in (fetch_in),
        .take_branch(take_branch),
        .branch_target(branch_target),
        .Imem_data({memory.unified_memory[PC_reg[15:3]], memory.unified_memory[PC_reg[15:3] + 4]}),
        //.Imem2proc_transaction_tag(Imem2proc_transaction_tag),
        //.Imem2proc_data_tag(Imem2proc_data_tag),
        //.Imem_command(Imem_command),
        .fetch_out(fetch_out),
        //.Imem_addr(Imem_addr)
        .PC_reg(PC_reg)
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

    assign inst1 = fetch_out.f_dat[0].inst;
    assign inst2 = fetch_out.f_dat[1].inst;
    assign pc1 = fetch_out.f_dat[0].PC;
    assign pc2 = fetch_out.f_dat[1].PC;
    assign valid1 = fetch_out.f_dat[0].valid;
    assign valid2 = fetch_out.f_dat[1].valid;

    // Generate random numbers for our write data on each cycle
    // always @(negedge clock) begin
    //     std::randomize();
    // end

    initial begin

        //Instantiate mem module to give it initial values, then try modifying unified memory in here
        $dumpfile("../ROB.vcd");
        $dumpvars(0, fetch_test.dut);
        $display("\nStart Testbench");

        clock = 0;
        reset = 1;
        fetch_in.d_rdy_cnt = 2'b00;
        take_branch = 0;
        branch_target = 0;

        $monitor("  %3d | branch?: %b  target: %d  |  mem_data: %h  | inst1: %h  inst2: %h  pc1: %d  pc2: %d  valid1: %b  valid2: %b  pc: %d",
                  $time,  take_branch, branch_target, memory.unified_memory[PC_reg[15:3]], inst1, inst2, pc1, pc2, valid1, valid2, PC_reg);

        @(negedge clock);
        @(negedge clock);
        for (int i=0; i < `MEM_64BIT_LINES; i++) begin
            memory.unified_memory[i] = i;
        end

#1;
        $display("Value from memory: %0x", memory.unified_memory[1]);
        $display(memory.unified_memory[2]);
        reset = 0;

        // ---------- Test 1 ---------- //
        fetch_in.d_rdy_cnt = 2'b01;
        @(negedge clock);
        fetch_in.d_rdy_cnt = 2'b00;

        // ---------- Test 2 ---------- //
        fetch_in.d_rdy_cnt = 2'b10;
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
