`timescale 1ns / 1ps

`define DCACHE_OP_READ 1
`define DCACHE_OP_WRITE 0

`include "sys_defs.svh"

module dcache_test;

    // Parameters
    localparam ASSOC        = 4;
    localparam NUM_MSHRS    = 16;
    localparam NUM_READ     = 2;

    // Clock and Reset
    logic clock;
    logic reset;

    // Instantiate the DUT
    dcache dut (
    );

    // Clock generation
    always #5 clock = ~clock;
    always @(negedge clock) begin
        #0;
    end

    task do_reset();
        reset = 1;
        @(negedge clock);
        reset = 0;
    endtask

    initial begin
        $display("Starting dcache testbench...");
        clock = 0;
        reset = 0;

        do_reset();
        @(negedge clock);

        @(negedge clock);
        @(negedge clock);
        $display("Finished dcache testbench.");
        $finish;
    end

endmodule