`timescale 1ns / 1ps
`include "sys_defs.svh"
module dcache_simple_test;

    // Clock and reset
    logic clock;
    logic reset;

    // DUT interface signals
    MEM_TAG       Dmem2Dcache_transaction_tag;
    MEM_BLOCK     Dmem2Dcache_data;
    MEM_TAG       Dmem2Dcache_data_tag;

    logic         Dcache_valid_in;
    MEM_COMMAND   proc2Dcache_command;
    ADDR          proc2Dcache_addr;
    MEM_SIZE      proc2Dcache_size;
    MEM_BLOCK     proc2Dcache_wdata;

    logic         Dcache_valid_out;
    MEM_BLOCK     Dcache_data_out;
    MEM_COMMAND   Dcache2Dmem_command;
    ADDR          Dcache2Dmem_addr;
    MEM_BLOCK     Dcache2Dmem_wdata;
    logic         mem_in_use;
    logic         dcache_ready;

    // Clock generation

    always begin
        #5;
        clock = ~clock;
    end

    always @(posedge clock) begin
        display_all_signals();
    end

    // Instantiate the DUT
    dcache_simple dut (
        .clock(clock),
        .reset(reset),
        .Dmem2Dcache_transaction_tag(Dmem2Dcache_transaction_tag),
        .Dmem2Dcache_data(Dmem2Dcache_data),
        .Dmem2Dcache_data_tag(Dmem2Dcache_data_tag),
        .Dcache_valid_in(Dcache_valid_in),
        .proc2Dcache_command(proc2Dcache_command),
        .proc2Dcache_addr(proc2Dcache_addr),
        .proc2Dcache_size(proc2Dcache_size),
        .proc2Dcache_wdata(proc2Dcache_wdata),
        .Dcache_valid_out(Dcache_valid_out),
        .Dcache_data_out(Dcache_data_out),
        .Dcache2Dmem_command(Dcache2Dmem_command),
        .Dcache2Dmem_addr(Dcache2Dmem_addr),
        .Dcache2Dmem_wdata(Dcache2Dmem_wdata),
        .mem_in_use(mem_in_use),
        .dcache_ready(dcache_ready)
    );


    mem memory (
        // Inputs
        .clock              (clock),
        .proc2mem_command   (Dcache2Dmem_command),
        .proc2mem_addr      (Dcache2Dmem_addr),
        .proc2mem_data      (Dcache2Dmem_wdata),

        // Outputs
        .mem2proc_transaction_tag   (Dmem2Dcache_transaction_tag),
        .mem2proc_data              (Dmem2Dcache_data),
        .mem2proc_data_tag          (Dmem2Dcache_data_tag)
    );

    // Task to display internal signals
    task display_all_signals();
        $display("Time: %0t", $time);
        $display("Inputs:");
        $display("  Dcache_valid_in: %b", Dcache_valid_in);
        $display("  proc2Dcache_command: %0d", proc2Dcache_command);
        $display("  proc2Dcache_addr: 0x%h", proc2Dcache_addr);
        $display("  proc2Dcache_size: %0d", proc2Dcache_size);
        $display("  proc2Dcache_wdata: 0x%h", proc2Dcache_wdata);
        $display("  Dmem2Dcache_transaction_tag: %0d", Dmem2Dcache_transaction_tag);
        $display("  Dmem2Dcache_data: 0x%h", Dmem2Dcache_data);
        $display("  Dmem2Dcache_data_tag: %0d", Dmem2Dcache_data_tag);
        $display("Outputs:");
        $display("  Dcache_valid_out: %b", Dcache_valid_out);
        $display("  Dcache_data_out: 0x%h", Dcache_data_out);
        $display("  Dcache2Dmem_command: %0d", Dcache2Dmem_command);
        $display("  Dcache2Dmem_addr: 0x%h", Dcache2Dmem_addr);
        $display("  Dcache2Dmem_wdata: 0x%h", Dcache2Dmem_wdata);
        $display("  mem_in_use: %b", mem_in_use);
        $display("  dcache_ready: %b", dcache_ready);
        $display("Internal Signals:");
        $display("  cache hit: %d", dut.cache_hit);
        $display("  state: %0d   |   next_state: %0d", dut.state, dut.next_state);
        $display("  current_tag: 0x%h", dut.current_tag);
        $display("  current_index: 0x%h", dut.current_index);
        $display("  byte_addr: 0x%h", dut.byte_addr);
        $display("  rblock: 0x%h", dut.rblock);
        $display("  wblock: 0x%h", dut.wblock);
        $display("  we: %b", dut.we);
        $display("  curr_dcache_entry %p", dut.curr_dcache_entry);
        $display("  dcache_tags[%0d]: valid=%b, dirty=%b, tag=0x%h",
                dut.current_index,
                dut.dcache_tags[dut.current_index].valid,
                dut.dcache_tags[dut.current_index].dirty,
                dut.dcache_tags[dut.current_index].tag);
        $display("  dcache_req: %p", dut.dcache_req);
        $display("  mem_req: %p", dut.mem_req);
        $display("  mem_resp: %p", dut.mem_resp);
        $display("  next dcache_tags[%0d]: valid=%b, dirty=%b, tag=0x%h",
                dut.current_index,
                dut.next_dcache_tags[dut.current_index].valid,
                dut.next_dcache_tags[dut.current_index].dirty,
                dut.next_dcache_tags[dut.current_index].tag);
        $display("  next dcache_req: %p", dut.next_dcache_req);
        $display("  next mem_req: %p", dut.next_mem_req);
        $display("  next mem_resp: %p", dut.next_mem_resp);

        $display("D-Cache Tags:");
        for (int i = 0; i < `DCACHE_LINES; i++) begin
            $display("Index %0d: valid=%b, dirty=%b, tag=0x%h",
                    i,
                    dut.dcache_tags[i].valid,
                    dut.dcache_tags[i].dirty,
                    dut.dcache_tags[i].tag);
        end

        // $display("memDP Contents:");
        // for (int i = 0; i < `DCACHE_LINES; i++) begin
        //     $display("Index %0d: Data = 0x%h", i, dut.dcache_mem.memData[i]);
        // end
        
        $display("--------------------------------------------------");
    endtask

    // Test sequence
    initial begin
        // Initialize inputs
        clock = 0;
        reset = 1;
        Dcache_valid_in = 0;
        proc2Dcache_command = MEM_NONE;
        proc2Dcache_addr = '0;
        proc2Dcache_size = BYTE;
        proc2Dcache_wdata = '0;
        // Dmem2Dcache_transaction_tag = 0;
        // Dmem2Dcache_data = '0;
        // Dmem2Dcache_data_tag = 0;

        // Apply reset
        @(negedge clock);
        reset = 0;

        // Wait for a few cycles
        @(negedge clock);
        @(negedge clock);

        // test 1: store miss
        Dcache_valid_in = 1;
        proc2Dcache_command = MEM_STORE;
        proc2Dcache_addr = 32'h0000_0008;
        proc2Dcache_size = WORD;
        proc2Dcache_wdata = 64'hDEADBEEF_DEADBEEF;
        #10;
        Dcache_valid_in = 0;


        @(negedge clock);
        Dcache_valid_in = 0;
        proc2Dcache_command = MEM_NONE;
        proc2Dcache_addr = 32'h0000_0000;
        proc2Dcache_size = WORD;
        proc2Dcache_wdata = 64'd0;
        //Dmem2Dcache_transaction_tag = 1;
        

        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        // Dmem2Dcache_transaction_tag = 0;
        // Dmem2Dcache_data = 64'hFACEFACEFACEFACE;
        // Dmem2Dcache_data_tag = 1;

        @(negedge clock);
        // Dmem2Dcache_transaction_tag = 0;
        // Dmem2Dcache_data = 0;
        // Dmem2Dcache_data_tag = 0;
        @(negedge clock);

        // test 2: load hit
        Dcache_valid_in = 1;
        proc2Dcache_command = MEM_LOAD;
        proc2Dcache_addr = 32'h0000_0008;
        proc2Dcache_size = DOUBLE;

        // test 3: load miss
        @(negedge clock);
        Dcache_valid_in = 1;
        proc2Dcache_command = MEM_LOAD;
        proc2Dcache_addr = 32'h0000_1000;
        proc2Dcache_size = DOUBLE;

        @(negedge clock);
        Dcache_valid_in = 0;
        proc2Dcache_command = MEM_NONE;
        proc2Dcache_addr = 32'h0000_0000;
        proc2Dcache_size = WORD;
        proc2Dcache_wdata = 64'd0;
        // Dmem2Dcache_transaction_tag = 2;

        @(negedge clock);
        @(negedge clock);
        // Dmem2Dcache_transaction_tag = 0;
        // Dmem2Dcache_data = 64'h1234123412341234;
        // Dmem2Dcache_data_tag = 2;

        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);

        //test 4: store hit
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
         @(negedge clock);
        @(negedge clock);
         @(negedge clock);
        @(negedge clock);
        // for (int i=0; i< `MEM_64BIT_LINES; i++) begin
        //     $display(memory.unified_memory[i]);
        // end
        @(negedge clock);
        Dcache_valid_in = 1;
        proc2Dcache_command = MEM_STORE;
        proc2Dcache_addr = 32'h0000_1000;
        proc2Dcache_size = HALF;
        proc2Dcache_wdata = 64'h8989898989898989;

        @(negedge clock);
        @(negedge clock);




        $finish;
    end



endmodule