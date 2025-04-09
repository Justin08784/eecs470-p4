`timescale 1ns / 1ps

`define DCACHE_OP_READ 1
`define DCACHE_OP_WRITE 0

`include "sys_defs.svh"

module dcache_test;

  // Parameters
  localparam ASSOCIATIVITY = 4;
  localparam NUM_MSHRS = 16;

  // Clock and Reset
  logic clock;
  logic reset;

  // Type definitions
  typedef logic [1:0] MEM_COMMAND;
  typedef logic [31:0] ADDR;
  typedef logic [63:0] MEM_BLOCK;
  typedef logic [63:0] DATA;
  typedef logic [3:0] MEM_TAG;

//   typedef enum logic [1:0] {
//     BYTE   = 2'h0,
//     HALF   = 2'h1,
//     WORD   = 2'h2,
//     DOUBLE = 2'h3
//   } MEM_SIZE;

  // Inputs
  logic          Dcache_valid_in;
  MEM_COMMAND    proc2Dcache_command;
  ADDR           proc2Dcache_addr;
  MEM_BLOCK      proc2Dcache_wdata;
  MEM_SIZE       proc2Dcache_size;
  MEM_TAG        Dmem2Dcache_transaction_tag;
  MEM_BLOCK      Dmem2Dcache_data;
  MEM_TAG        Dmem2Dcache_data_tag;

  // Outputs
  logic          Dcache_valid_out;
  MEM_BLOCK      Dcache_data_out;
  MEM_COMMAND    Dcache2Dmem_command;
  ADDR           Dcache2Dmem_addr;

  // Instantiate the DUT
  dcache #(
    .ASSOCIATIVITY(ASSOCIATIVITY),
    .NUM_MSHRS(NUM_MSHRS)
  ) dut (
    .clock(clock),
    .reset(reset),
    .Dmem2Dcache_transaction_tag(Dmem2Dcache_transaction_tag),
    .Dmem2Dcache_data(Dmem2Dcache_data),
    .Dmem2Dcache_data_tag(Dmem2Dcache_data_tag),
    .Dcache_valid_in(Dcache_valid_in),
    .proc2Dcache_command(proc2Dcache_command),
    .proc2Dcache_addr(proc2Dcache_addr),
    .proc2Dcache_wdata(proc2Dcache_wdata),
    .proc2Dcache_size(proc2Dcache_size),
    .Dcache_valid_out(Dcache_valid_out),
    .Dcache_data_out(Dcache_data_out),
    .Dcache2Dmem_command(Dcache2Dmem_command),
    .Dcache2Dmem_addr(Dcache2Dmem_addr)
  );

  // Clock generation
  always #5 clock = ~clock;
  always @(negedge clock) begin
    print_state();
  end

  task do_reset();
    reset = 1;
    @(negedge clock);
    reset = 0;
  endtask

  task store(input ADDR addr, input MEM_BLOCK data);
    proc2Dcache_command = 2'd2; // MEM_STORE
    proc2Dcache_addr = addr;
    proc2Dcache_wdata = data;
    proc2Dcache_size = 2'h3; //double
    // @(negedge clock);
    // proc2Dcache_command = 2'd0; // MEM_NONE
  endtask

  task load(input ADDR addr);
    proc2Dcache_command = 2'd1; // MEM_LOAD
    proc2Dcache_addr = addr;
    proc2Dcache_size = 2'h3; // double
    // @(negedge clock);
    // proc2Dcache_command = 2'd0;
  endtask

  task respond_from_mem(input MEM_TAG tag, input MEM_BLOCK data);
    //Dmem2Dcache_transaction_tag = tag;
    Dmem2Dcache_data_tag = tag;
    Dmem2Dcache_data = data;
    // @(negedge clock);
    // Dmem2Dcache_data_tag = 0;
  endtask

  // task check_load_result(input logic expected_valid, input MEM_BLOCK expected_data);
  //   if (Dcache_valid_out !== expected_valid) begin
  //       $error("FAIL: Expected valid_out = %0d, got %0d", expected_valid, Dcache_valid_out);
  //   end
  //   if (expected_valid && Dcache_data_out !== expected_data) begin
  //       $error("FAIL: Expected data_out = %h, got %h", expected_data, Dcache_data_out);
  //   end else if (expected_valid) begin
  //       $display("PASS: Load returned correct data = %h", Dcache_data_out);
  //   end
  // endtask

  task print_state();
    $display("==================================================");
    $display("Time: %0t", $time);
    $display("--- Inputs to dcache ---");
    $display("Dcache_valid_in           = %0b", Dcache_valid_in);
    $display("proc2Dcache_command       = %0d", proc2Dcache_command);
    $display("proc2Dcache_addr          = %h", proc2Dcache_addr);
    $display("proc2Dcache_wdata         = %h", proc2Dcache_wdata);
    $display("proc2Dcache_size          = %0d", proc2Dcache_size);
    $display("Dmem2Dcache_transaction_tag = %0d", Dmem2Dcache_transaction_tag);
    $display("Dmem2Dcache_data          = %h", Dmem2Dcache_data);
    $display("Dmem2Dcache_data_tag      = %0d", Dmem2Dcache_data_tag);

    $display("--- Outputs from dcache ---");
    $display("Dcache_valid_out          = %0b", Dcache_valid_out);
    $display("Dcache_data_out           = %h", Dcache_data_out);
    $display("Dcache2Dmem_command       = %0d", Dcache2Dmem_command);
    $display("Dcache2Dmem_addr          = %h", Dcache2Dmem_addr);


    $display("\n--- internal signal ---");
    $display("current_read_tag %d", dut.current_read_tag);
    $display("current_write_tag %d", dut.current_write_tag);
    $display("current_read_set_index %d", dut.current_read_set_index);
    $display("current_write_set_index %d", dut.current_write_set_index);
    $display("cache_hit %d", dut.cache_hit);
    $display("hit_way %d", dut.hit_way);
    $display("read_operation %d", dut.read_operation);
    $display("write_store %d", dut.write_store);
    $display("write_mshr %d", dut.write_mshr);
   // $display("write_source %d", dut.write_source);
    
    $display("\n--- memDP I/O ---");
    for (int w = 0; w < dut.ASSOCIATIVITY; w++) begin
    $display("Way %0d | RE: %0d | RADDR: %0d | RDATA: %h | WE: %0d | WADDR: %0d | WDATA: %h",
        w,
        dut.re_array[w],
        dut.raddr_array[w],
        dut.rdata_array[w],
        dut.we_array[w],
        dut.waddr_array[w],
        dut.wdata_array[w]
    );
    end
    $display("--- DCache Tags ---");
    for (int s = 0; s < dut.NUM_SETS; s++) begin
        for (int w = 0; w < dut.ASSOCIATIVITY; w++) begin
        $display("Set %0d Way %0d | Valid: %0d | Tag: %d", s, w, dut.dcache[s][w].valid, dut.dcache[s][w].tag);
        end
    end
    $display("--- LRU vs LRU update---");
    for (int s = 0; s < dut.NUM_SETS; s++) begin
        $write("Set %0d: ", s);
        $write("| LRU ");
        for (int i = 0; i < dut.ASSOCIATIVITY; i++) begin
        $write("%0d ", dut.lru[s][i]);
        end
        $write("| LRU_updates ");
        for (int i = 0; i < dut.ASSOCIATIVITY; i++) begin
        $write("%0d ", dut.lru_updates[s][i]);
        end
        $display("");
    end

    $display("--- LRU way ---");
    for (int s = 0; s < dut.NUM_SETS; s++) begin
        $display("Set %0d: | LRU %d ", s, dut.lru_way[s]);
        $display("");
    end

    $display("--- MSHR ---");
    for (int m = 0; m < dut.NUM_MSHRS; m++) begin
        //if (dut.mshr[m].allocated || dut.mshr[m].ready) begin
        $display("MSHR %0d | Alloc: %0d | Ready: %0d | Addr: %h | Trans_Tag: %0d | Data: %h",
            m, dut.mshr[m].allocated, dut.mshr[m].ready,
            dut.mshr[m].addr, dut.mshr[m].trans_tag, dut.mshr[m].mem_data);
        //end
    end
     $display("--- MSHR Complete ---");
     for (int m = 0; m < dut.NUM_MSHRS; m++) begin
        $display("MSHR %0d | mshr_complete %0d", m, dut.mshr_complete[m]);
     end
    $display("==================================================\n");
  endtask

  initial begin
    $display("Starting dcache testbench...");
    clock = 0;
    reset = 0;
    Dcache_valid_in = 0;
    proc2Dcache_command = 2'd0;
    proc2Dcache_addr = 0;
    proc2Dcache_wdata = 0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 0;
    Dmem2Dcache_data_tag = 0;
    Dmem2Dcache_data = 0;

    do_reset();
    //print_state();

    @(negedge clock);
    // Test: Store to address 0x1000
    $display("Storing 0xdeadbeefcafebabe at 0x1000");
    proc2Dcache_command = MEM_STORE;
    proc2Dcache_addr = 32'h1000;
    proc2Dcache_wdata = 64'hdeadbeefcafebabe;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 0;
    Dmem2Dcache_data_tag = 0;
    Dmem2Dcache_data = 0;
    //store(32'h1000, 64'hdeadbeefcafebabe);

    //print_state();

    // Test: Load from 0x1000 (expect hit)
    // Load from 0x1000 (expect hit)
    // @(negedge clock);
    // $display("Loading from 0x1000 - expect hit");
    // load(32'h1000);
   // check_load_result(1'b1, 64'hdeadbeefcafebabe);

    // Load from 0x2000 (expect miss)
    @(negedge clock);
    $display("Loading from 0x2000 - expect miss");
    //load(32'h2000);
    proc2Dcache_command = MEM_LOAD;
    proc2Dcache_addr = 32'h2000;
    proc2Dcache_wdata = 64'd0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 0;
    Dmem2Dcache_data_tag = 0;
    Dmem2Dcache_data = 0;
    //print_state();
    //check_load_result(1'b0, 64'h0); // Dcache_data_out should be ignored

    // Simulate mem response for 0x2000 (tag = 1)
    @(negedge clock);
    $display("Loading from 0x3000 - expect miss, get transtag = 1 for Loading from 0x2000");
    proc2Dcache_command = MEM_LOAD;
    proc2Dcache_addr = 32'h3000;
    proc2Dcache_wdata = 64'd0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 1;
    Dmem2Dcache_data_tag = 0;
    Dmem2Dcache_data = 0;
    
    // load(32'h3000);
    // Dmem2Dcache_transaction_tag = 2;
    //print_state();

    @(negedge clock);
    $display("Loading from 0x4000 - expect miss , get transtag = 2 for Loading from 0x3000");
    proc2Dcache_command = MEM_LOAD;
    proc2Dcache_addr = 32'h4000;
    proc2Dcache_wdata = 64'd0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 2;
    Dmem2Dcache_data_tag = 0;
    Dmem2Dcache_data = 0;
    // load(32'h4000);
    // Dmem2Dcache_transaction_tag = 3;
    //print_state();
    
    @(negedge clock);
    $display("MEM_NONE , get transtag = 3 for Loading from 0x4000");
    // proc2Dcache_command = MEM_NONE;
    //print_state();
    proc2Dcache_command = MEM_NONE;
    proc2Dcache_addr = 32'h0000;
    proc2Dcache_wdata = 64'd0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 3;
    Dmem2Dcache_data_tag = 0;
    Dmem2Dcache_data = 0;


    @(negedge clock);
    
    $display("Memory returns data for 0x2000 (tag = 1)");
    // respond_from_mem(4'd1, 64'h1122334455667788);
    // //print_state();
    proc2Dcache_command = MEM_NONE;
    proc2Dcache_addr = 32'h0000;
    proc2Dcache_wdata = 64'd0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 0;
    Dmem2Dcache_data_tag = 1;
    Dmem2Dcache_data = 64'h1122334455667788;

    // Load from 0x2000 again (expect hit)
    @(negedge clock);
    $display("Loading from 0x2000 again - expect hit");
    proc2Dcache_command = MEM_LOAD;
    proc2Dcache_addr = 32'h2000;
    proc2Dcache_wdata = 64'd0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 0;
    Dmem2Dcache_data_tag = 0;
    Dmem2Dcache_data = 0;
    //$display("Memory returns data for 0x3000 (tag = 2)");
    //load(32'h2000);
    //respond_from_mem(4'd2, 64'h2222334455667788);
    //print_state();
    //check_load_result(1'b1, 64'h1122334455667788);

    @(negedge clock);
    $display("Memory returns data for 0x3000 (tag = 2)");
    $display("Storing 0xfacebeeffacebeef at 0x5000");
    proc2Dcache_command = MEM_STORE;
    proc2Dcache_addr = 32'h5000;
    proc2Dcache_wdata = 64'hfacebeeffacebeef;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 0;
    Dmem2Dcache_data_tag = 2;
    Dmem2Dcache_data = 64'h2222334455667788;
    //respond_from_mem(4'd3, 64'h3333334455667788);
    
    // store(32'h5000, 64'hfacebeeffacebeef);
    // respond_from_mem(4'd3, 64'h3333334455667788);
    //print_state();


    @(negedge clock);
    proc2Dcache_command = MEM_NONE;
    proc2Dcache_addr = 32'h0000;
    proc2Dcache_wdata = 64'd0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 0;
    Dmem2Dcache_data_tag = 0;
    Dmem2Dcache_data = 64'd0;

    //print_state();
    @(negedge clock);
    $display("Memory returns data for 0x4000 (tag = 3)");
    $display("Loading from 0x3000 again - expect hit");
    proc2Dcache_command = MEM_LOAD;
    proc2Dcache_addr = 32'h3000;
    proc2Dcache_wdata = 64'd0;
    proc2Dcache_size = 2'h3;
    Dmem2Dcache_transaction_tag = 0;
    Dmem2Dcache_data_tag = 3;
    Dmem2Dcache_data = 64'h3333334455667788;

    @(negedge clock);
    //print_state();
    @(negedge clock);
    //print_state();
    @(negedge clock);
    //print_state();
    $display("Finished dcache testbench.");
    $finish;
  end

endmodule