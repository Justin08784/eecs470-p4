`include "sys_defs.svh"

module btb_tb;

  parameter N = 2;

  logic clock, reset;

 
  fetch2btb    fetch_in;

  retire2btb  retire_in;

  btb2fetch    fetch_out;

 
  btb dut (
    .clock(clock),
    .reset(reset),
    .fetch_in(fetch_in),
    .retire_in(retire_in),
    .fetch_out(fetch_out)
  );

  always #5 clock = ~clock;

  
  initial begin
    clock = 0;
    reset = 1;
    @(negedge clock);
    @(negedge clock); 
    reset = 0;


 //   $display("Before inputting", fetch_out.hit[0]);
   //  $display("Before inputting", fetch_out.hit[1]);

    // Cycle 1: send taken branch
    retire_in.PC[0] = 32'h00000100;
    retire_in.is_taken[0] = 1;
    retire_in.target[0] = 16'h00AA;//12'h0AA;

    retire_in.PC[1] = 32'h00000104;
    retire_in.is_taken[1] = 0;
    retire_in.target[1] = 0;

    @(negedge clock); // Commit write to BTB

    // Cycle 2: Check prediction from fetch
    fetch_in.PC[0] = 32'h00000100;
    fetch_in.PC[1] = 32'h00000104;

    @(negedge clock); // Read outputs after full cycle

    if (!fetch_out.hit[0]) begin
      $display("fetch_out.hit[0] = %b (expected 1)", fetch_out.hit[0]);
      $fatal("Missed hit!");
    end

    if (fetch_out.target[0] !==  16'h00AA/*12'h0AA*/) begin
      $display("fetch_out.target[0] = 0x%0h (expected 0x0AA)", fetch_out.target[0]);
      $fatal("Wrong target!");
    end

    if (fetch_out.hit[1]) begin
      $display("fetch_out.hit[1] = %b (expected 0)", fetch_out.hit[1]);
      $fatal("Unexpected hit!");
    end


    @(negedge clock);
        // --------------------------
    // Cycle 3: Test BTB miss for unseen PC
    // --------------------------
   // $display("Before inputting", fetch_out.hit[0]);
    fetch_in.PC[0] = 32'h00000200; // new PC, not trained
    fetch_in.PC[1] = 32'h00000204;

    @(negedge clock);

    if (fetch_out.hit[0]) begin
      $display("Expected miss at PC=0x200, got hit!", fetch_out.hit[0]);
      $fatal("Cold-start hit failure");
    end

    if (fetch_out.hit[1]) begin
      $display("Expected miss at PC=0x204, got hit!");
      $fatal("Cold-start hit failure");
    end

    // --------------------------
    // Cycle 4: Same index, different tag → should miss
    // --------------------------
    // 0x00000100 and 0x00002100 have same index [9:2]
    fetch_in.PC[0] = 32'h00002100;

    @(negedge clock);

    if (fetch_out.hit[0]) begin
      $display("Tag mismatch not detected: expected miss at 0x2100");
      $fatal("BTB tag aliasing failure");
    end

    // --------------------------
    // Cycle 5: Train second entry at PC = 0x00000200
    // --------------------------
    retire_in.PC[0] = 32'h00000200;
    retire_in.is_taken[0] = 1;
    retire_in.target[0] = 16'h0123; //12'h123;

    retire_in.PC[1] = 32'h00000204;
    retire_in.is_taken[1] = 1;
    retire_in.target[1] = 16'h0456;//12'h456;

    @(negedge clock); // write to BTB

    fetch_in.PC[0] = 32'h00000200;
    fetch_in.PC[1] = 32'h00000204;

    @(negedge clock); // read back

    if (!fetch_out.hit[0] || fetch_out.target[0] !== 16'h0123/*12'h123*/) begin
      $display("Mismatch for 0x200 → got target %h (hit = %b)", fetch_out.target[0], fetch_out.hit[0]);
      $fatal("Multiple entry check failed (0x200)");
    end

    if (!fetch_out.hit[1] || fetch_out.target[1] !== 16'h0456/*12'h456*/) begin
      $display("Mismatch for 0x204 → got target %h (hit = %b)", fetch_out.target[1], fetch_out.hit[1]);
      $fatal("Multiple entry check failed (0x204)");
    end

    // --------------------------
    // Cycle 6: Overwrite target at 0x00000100
    // --------------------------
    retire_in.PC[0] = 32'h00000100;
    retire_in.is_taken[0] = 1;
    retire_in.target[0] = 16'h00BB; //12'h0BB; // different target now

    retire_in.is_taken[1] = 0;

    @(negedge clock);

    fetch_in.PC[0] = 32'h00000100;

    @(negedge clock);

    if (!fetch_out.hit[0] || fetch_out.target[0] !== 16'h00BB/*12'h0BB*/) begin
      $display("Target overwrite failed — got %h, expected 0x0BB", fetch_out.target[0]);
      $fatal("Overwrite test failed");
    end

    // --------------------------
    // Cycle 7: Reset BTB and verify cleared
    // --------------------------
    reset = 1;
    @(negedge clock);
    @(negedge clock);
    reset = 0;

    retire_in.PC[0] = '0;
    retire_in.PC[1] = '0;
    retire_in.is_taken = '0;
    retire_in.target = '0;

    fetch_in.PC[0] = 32'h00000100;
    fetch_in.PC[1] = 32'h00000200;

    @(negedge clock);

    if (fetch_out.hit[0] || fetch_out.hit[1]) begin
      $display("Reset failed — stale BTB entries still producing hits");
      $fatal("Reset test failed");
    end

    $display("All BTB test cases passed!");
    $finish;


    $display("BTB test passed!");
    $finish;
  end

endmodule
