`include "sys_defs.svh"

module gshare_predictor_tb;

  // Clock + Reset
  logic clock, reset;

  // Inputs
  fetch2predictor    fetch_2_pred;
  retire2predictor   ret_2_pred;

  // Output
  logic [`N-1:0]     predict_taken;

  // DUT
  gshare dut (
    .clock(clock),
    .reset(reset),
    .fetch_2_pred(fetch_2_pred),
    .ret_2_pred(ret_2_pred),
    .predict_taken(predict_taken)
  );

  // Clock generation
  always #5 clock = ~clock;

  // Test sequence
  initial begin
    clock = 0;
    reset = 1;
    fetch_2_pred = '0;
    ret_2_pred = '0;

    @(negedge clock);
    reset = 0;

    // ----------------------------------
    // Cycle 1: Fetch branch at PC = 0x80
    // ----------------------------------
    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 1 prediction (PC=0x80): %b", predict_taken[0]);

    // ----------------------------------
    // Cycle 2: Retire that branch as taken
    // ----------------------------------
    ret_2_pred.PC[0] = 32'h00000080;
    ret_2_pred.taken[0] = 1'b1;
    ret_2_pred.update_enable[0] = 1'b1;

    @(negedge clock); // Let it update

    // ----------------------------------
    // Cycle 3: Fetch again — check if predictor learned
    // ----------------------------------
    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 3 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 4 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 5 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 6 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 7 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 8 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 9 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 10 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 11 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 12 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 13 prediction (after training): %b", predict_taken[0]);

    fetch_2_pred.PC[0] = 32'h00000080;

    @(negedge clock);
    $display("Cycle 14 prediction (after training): %b", predict_taken[0]);

    

    if (predict_taken[0] !== 1'b1) begin
      $fatal("❌ Predictor failed to learn — expected 1 at PC=0x80");
    end else begin
      $display("✅ Predictor correctly trained and returned taken");
    end

    $finish;
  end

endmodule
