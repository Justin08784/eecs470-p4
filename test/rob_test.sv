// FIFO module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh
`include "sys_defs.svh"
`include "FIFO_sva.svh"



`ifndef WIDTH
  `define WIDTH $bits(robItem)
`endif

`ifndef DEPTH
  `define DEPTH 32
`endif



module rob_test();

    localparam CNT_BITS = $clog2(`DEPTH);

    logic                clock, reset;
    logic          [1:0] wr_en;
    logic [1:0] [`WIDTH-1:0] wr_data;
    logic                err;
    logic          [1:0] rd_en;
    logic [1:0] [`WIDTH-1:0] rd_data;
    logic          [1:0] rd_valid;
    logic          [1:0] wr_valid;
    logic   [CNT_BITS:0] spots;
    logic                full;

    // variable to count values written to FIFO
    int cnt;

    // INSTANCE is from the sys_defs.svh file
    // it renames the module if SYNTH is defined in
    // order to rename the module to FIFO_svsim
    rob dut (
        .clock    (clock),
        .reset    (reset),
        .dispatch_en (wr_en),
        .retire_en (rd_en),
        .err      (err),
        .next_insn (wr_data),
        .wr_valid (wr_valid),
        .rd_valid (rd_valid),
        // .rd_data  (rd_data),
        // .spots    (spots),
        .full     (full)
    );

    // bind dut FIFO_sva #(
    //     .DEPTH(`DEPTH),
    //     .WIDTH(`WIDTH)
    // ) DUT_sva (.*);

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    // Generate random numbers for our write data on each cycle
    always @(negedge clock) begin
        std::randomize(wr_data);
    end

    initial begin

        $dumpfile("../ROB.vcd");
        $dumpvars(0, rob_test.dut);
        $display("\nStart Testbench");

        clock = 1;
        reset = 1;
        wr_en = 2'b00;
        rd_en = 2'b00;
        err = 0;

        $monitor("  %3d | d_in: %h   wr: %b  rd: %b  |  wr_vld: %b  rd_vld: %b   d_out: %h   full: %b  spots: %2d",
                  $time,  wr_data,   wr_en, rd_en,      wr_valid,  rd_valid,     rd_data,    full,     spots);

        @(negedge clock);
        @(negedge clock);
        reset = 0;

        // ---------- Test 1 ---------- //
        $display("\nTest 1: invalid read");
        rd_en = 2'b01;
        @(negedge clock);
        rd_en = 2'b00;

        // ---------- Test 2 ---------- //
        $display("\nTest 2: Write and read with one cycle wait");
        $display("Write 1 value");
        wr_en = 2'b01;
        @(negedge clock);
        wr_en = 2'b00;

        $display("Wait one cycle");
        @(negedge clock);

        rd_en = 2'b01;
        $display("Read 1 value");
        @(negedge clock);
        rd_en = 2'b00;

        // ---------- Test 2.5 ---------- //
        $display("\nTest 2.5: Write and read twice with one cycle wait");
        $display("Write 1 value");
        wr_en = 2'b11;
        @(negedge clock);
        wr_en = 2'b00;

        $display("Wait one cycle");
        @(negedge clock);

        rd_en = 2'b11;
        $display("Read 1 value");
        @(negedge clock);
        rd_en = 2'b00;

        // // ---------- Test 3 ---------- //
        $display("\nTest 3: Write and read with no wait");
        $display("Write 1 value");
        wr_en = 2'b01;
        @(negedge clock);
        wr_en = 2'b00;

        rd_en = 2'b01;
        $display("Read 1 value");
        @(negedge clock);
        rd_en = 2'b00;

        // // ---------- Test 3.5 ---------- //
        $display("\nTest 3.5: Write and read twice with no wait");
        $display("Write 1 value");
        wr_en = 2'b11;
        @(negedge clock);
        wr_en = 2'b00;

        rd_en = 2'b11;
        $display("Read 1 value");
        @(negedge clock);
        rd_en = 2'b00;

        // // ---------- Test 4 ---------- //
        $display("\nTest 4: Read and write when empty");
        wr_en = 2'b11;
        rd_en = 2'b11;
        @(negedge clock);
        rd_en = 2'b00;

        // // ---------- Test 5 ---------- //
        $display("\nTest 5: Write 6 values");
        wr_en = 2'b11;
        repeat (2) @(negedge clock);
        wr_en = 2'b10;
        @(negedge clock);
        wr_en = 2'b01;
        @(negedge clock);
        wr_en = 2'b00;

        // // ---------- Test 6 ---------- //
        $display("\nTest 6: Read 4 values");
        rd_en = 2'b11;
        @(negedge clock);
        rd_en = 2'b10;
        @(negedge clock);
        rd_en = 2'b01;
        @(negedge clock);
        rd_en = 2'b00;

        // // ---------- Test 7 ---------- //
        $display("\nTest 7: Write until full");
        cnt = 2;
        wr_en = 2'b11;
        while (!full) begin
            cnt += 2;
            @(negedge clock);
        end

        // // ---------- Test 8 ---------- //
        $display("\nTest 8: Invalid write");
        wr_en = 2'b11;
        @(negedge clock);

        // // ---------- Test 9 ---------- //
        $display("\nTest 9: Simultaneous read and write when full");
        rd_en = 2'b11;
        @(negedge clock);
        wr_en = 2'b00;
        rd_en = 2'b00;
        @(negedge clock);

        // // ---------- Test 10 ---------- //
        $display("\nTest 10: Write when one less than full");
        rd_en = 2'b01;
        $display("Read one");
        @(negedge clock);
        $display("Write two");
        wr_en = 2'b11;
        rd_en = 2'b00;
        @(negedge clock);
        $display("Read another one");
        rd_en = 2'b10;
        @(negedge clock);
        wr_en = 2'b00;
        rd_en = 2'b00;
        @(negedge clock);

        // // ---------- Test 11 ---------- //
        $display("\nTest 11: Read all values");
        rd_en = 2'b11;
        while (cnt > 0) begin
            cnt -= 2;
            @(negedge clock);
        end

        // ---------- Test 12 ---------- //
        $display("\nTest 12: Invalid read");
        rd_en = 2'b11;
        @(negedge clock);
        rd_en = 2'b00;

        // ---------- Test 13 ---------- //
        $display("\nTest 13: Four simultaneous reads and writes");
        rd_en = 2'b10;
        wr_en = 2'b01;
        repeat (4) @(negedge clock);
        wr_en = 2'b00;

        // ---------- Test 14 ---------- //
        $display("\nTest 14: Read last item");
        @(negedge clock);
        rd_en = 2'b00;

        @(negedge clock);
        @(negedge clock);

        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end

endmodule
