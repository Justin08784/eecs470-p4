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
    MEM_BLOCK   mem_out_data;

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

    // Instantiate the Data Memory
    mem memory (
        // Inputs
        .clock              (clock),
        .proc2mem_command   (mem_out_command),
        .proc2mem_addr      (mem_out_addr),
        .proc2mem_data      (mem_out_data),

        // Outputs
        .mem2proc_transaction_tag   (mem_in_transaction_tag),
        .mem2proc_data              (mem_in_data),
        .mem2proc_data_tag          (mem_in_data_tag)
    );

    // Instantiate the DUT
    dcache dut (
        .dbg,
        .clock,
        .reset,

        .mem_in_transaction_tag,
        .mem_in_data,
        .mem_in_data_tag,

        .mem_out_command,
        .mem_out_addr,
        .mem_out_data,

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
        // #0;
        // $display("st_vld: %b", dut.st_vld);
        // $display("st_addr: %x", dut.st_addr);
        // $display("st_size: %1d", dut.st_size);
        // $display("st_status: %b", dut.st_status);
        // $display("st_dat: %x", dut.st_dat);
        // $display("req: %b", dut.req);
        // $display("gnt: %b", dut.gnt);
        print_dbg();
        $display("");
    end

    initial begin
        logic [3:0][15:0] half_template;
        for (logic [31:0] i = 0; i < `MEM_64BIT_LINES; ++i) begin
            if (i >= 256) begin
                memory.unified_memory[i] = '0;
                continue;
            end

            for (int half = 0; half < 4; ++half)
                half_template[half] = 4*i + half;
            memory.unified_memory[i] = half_template;
            $display("mem[%4x]: %x", 8*i, memory.unified_memory[i]);
        end

        $display("Starting dcache testbench...");
        clock = 0;
        reset = 0;
        clr_inputs();
        do_reset();

        wr(4, 'hbeeffeed, WORD);
        @(negedge clock);
        @(negedge clock);

        $display("Finished dcache testbench.");
        $finish;
    end

endmodule