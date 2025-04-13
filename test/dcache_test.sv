`timescale 1ns / 1ps
`include "sys_defs.svh"
`include "dcache.svh"

module dcache_test;
    // Clock and Reset
    logic clock;
    logic reset;

    // input from memory
    MEM_TAG     mem_in_transaction_tag;
    MEM_BLOCK   mem_in_data;
    MEM_TAG     mem_in_data_tag;
    MEM_COMMAND mem_out_command;
    ADDR        mem_out_addr;

    logic       ld_vld;
    ADDR        ld_addr;
    MEM_SIZE    ld_size;
    logic       ld_status;
    MEM_BLOCK   ld_dat;

    logic       st_vld;
    ADDR        st_addr;
    MEM_SIZE    st_size;
    logic       st_status;
    MEM_BLOCK   st_dat;

    // Instantiate the DUT
    dcache dut (
        .clock,
        .reset,

        .ld_vld,
        .ld_addr,
        .ld_size,
        .ld_status,
        .ld_dat,

        .st_vld,
        .st_addr,
        .st_size,
        .st_status
    );

    // task wr(
    //     input int v,
    //     input int addr
    // );
    //     wen     = 1;
    //     waddr   = addr;
    //     wdat    = v;
    // endtask

    // task rd(
    //     input int addr
    // );
    //     ren     = 1;
    //     raddr   = addr;
    // endtask

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