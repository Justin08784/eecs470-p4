`timescale 1ns / 1ps
`include "sys_defs.svh"
`include "dcache.svh"
/*
WARNING: This must be run in DEBUG mode. (it won't compile otherwise)
*/


module dcache_test;
    // DBG
    DBG_cache dbg;
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
        .dbg,
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
        .st_status,
        .st_dat
    );

    task rd(
        input ADDR      addr,
        input MEM_SIZE  sz
    );
        st_vld  = 1;
        st_addr = addr;
        st_size = sz;
    endtask

    task wr(
        input ADDR      addr,
        input MEM_BLOCK v,
        input MEM_SIZE  sz
    );
        st_vld  = 1;
        st_addr = addr;
        st_size = sz;
        st_dat  = v;
    endtask

    task do_reset();
        reset = 1;
        @(negedge clock);
        reset = 0;
    endtask

    task clr_inputs();
        {   
            mem_in_transaction_tag,
            mem_in_data,
            mem_in_data_tag,

            ld_vld,
            ld_addr,
            ld_size,

            st_vld,
            st_addr,
            st_size,
            st_dat
        } = '0;
    endtask

    task print_dbg();
        $display("  %3d | >> memDP", $time);
        for (int s = 0; s < NUM_SETS; ++s) begin
            $display("Set=%1d. age=%b", s, dbg.hdr.age[s]);
            for (int w = 0; w < ASSOC; ++w) begin
                $display("  vld=%b, dirty=%b, tag=%x: data=%x",
                    dbg.hdr.vld[s][w],
                    dbg.hdr.dirty[s][w],
                    dbg.hdr.tag[s][w],
                    dbg.state[s][w]
                );
            end
        end
        $display("  %3d | << memDP", $time);
    endtask

    // Clock generation
    always #5 clock = ~clock;
    always @(negedge clock) begin
        print_dbg();
        #0;
    end

    initial begin
        $display("Starting dcache testbench...");
        clock = 0;
        reset = 0;
        do_reset();
        clr_inputs();

        @(negedge clock);
        wr(0, 0'hbeeffeed, WORD);

        @(negedge clock);
        @(negedge clock);
        $display("Finished dcache testbench.");
        $finish;
    end

endmodule