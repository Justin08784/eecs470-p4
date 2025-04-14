`timescale 1ns / 1ps
`include "sys_defs.svh"
`include "dcache.svh"
/*
WARNING: This must be run in DEBUG mode. (it won't compile otherwise)
*/

function automatic string dbg_mem_cmd(input MEM_COMMAND cmd);
    string rv;
    case (cmd)
        MEM_NONE:   rv = "NONE";
        MEM_STORE:  rv = "STOR";
        MEM_LOAD:   rv = "LOAD";
    endcase
    return rv;
endfunction

function automatic string dbg_mem_size(input MEM_SIZE size);
    string rv;
    case (size)
        BYTE:   rv = "BYTE";
        HALF:   rv = "HALF";
        WORD:   rv = "WORD";
        DOUBLE: rv = "DBLE";
    endcase
    return rv;
endfunction

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
            for (int w = 0; w == 0; ++w) begin
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
    logic enable_prints = 0;
    localparam DCACHE_CLOCK = 50;
    always begin
        #(DCACHE_CLOCK/2);
        clock = ~clock;
    end
    always @(negedge clock) begin
        if (enable_prints) begin
            // #0;
            $display("lod in: {vld: %b, addr: %4x, size: %s}",
                ld_vld,
                ld_addr,
                dbg_mem_size(ld_size)
            );

            $display("lod ot: {status: %b, dat: %x}",
                ld_status,
                ld_dat
            );

            $display("str in: {vld: %b, addr: %4x, size: %s, dat: %x}",
                st_vld,
                st_addr,
                dbg_mem_size(st_size),
                st_dat
            );

            $display("str ot: {status: %b}",
                st_status
            );

            $display("mem in: {txn_tag: %2d, dat: %x, dat_tag: %2d}",
                mem_in_transaction_tag,
                mem_in_data,
                mem_in_data_tag
            );
            $display("vld addres: %b", memory.valid_address);

            $display("mem ot: {cmd: %s, addr: %4x, dat: %x}",
                dbg_mem_cmd(mem_out_command),
                mem_out_addr,
                mem_out_data
            );

            // $display("st_vld: %b", dut.st_vld);
            // $display("st_addr: %x", dut.st_addr);
            // $display("st_size: %1d", dut.st_size);
            // $display("st_status: %b", dut.st_status);
            // $display("st_dat: %x", dut.st_dat);
            $display("req: %b", dut.req);
            $display("gnt: %b", dut.gnt);
            print_dbg();
            $display("");
        end
    end

    initial begin
        logic [3:0][15:0] half_template;

        $display("Starting dcache testbench...");
        clock = 0;
        reset = 0;
        clr_inputs();

        $display("\n  %16t : Asserting Reset", $realtime);
        reset = 1;
        for (int i = 0; i < 6; ++i)
            @(negedge clock);
        $display("  %16t : Loading Unified Memory", $realtime);
        for (logic [31:0] i = 0; i < `MEM_64BIT_LINES; ++i) begin
            if (i >= 256) begin
                memory.unified_memory[i] = '0;
                continue;
            end

            for (int half = 0; half < 4; ++half)
                half_template[half] = 4*i + half;
            memory.unified_memory[i] = half_template;
            // $display("mem[%4x]: %x", 8*i, memory.unified_memory[i]);
        end
        #1;
        $display("  %16t : Deasserting Reset", $realtime);
        reset = 0;
        enable_prints = 1;

        wr('h80, 'hbeeffeed, WORD);
        @(negedge clock);
        clr_inputs();
        for (int i = 0; i < 10; ++i)
            @(negedge clock);

        $display("Finished dcache testbench.");
        $finish;
    end

endmodule