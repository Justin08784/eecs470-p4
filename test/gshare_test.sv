`include "sys_defs.svh"

module gshare_predictor_tb;

  parameter N = 2;

  logic clock, reset;

  fetch2predictor    fetch_2_pred;
  retire2predictor   ret_2_pred;
  logic [N-1:0]      predict_taken;

  gshare dut (
    .clock(clock),
    .reset(reset),
    .fetch_2_pred(fetch_2_pred),
    .ret_2_pred(ret_2_pred),
    .predict_taken(predict_taken)
  );

  // Clock generation
  always #5 clock = ~clock;
  // Helper macros
  task show_predictions(string label);
    $display("Cycle %s:", label);
    $display("  PC 0x%0h: predict_taken[0] = %0b", fetch_2_pred.PC[0], predict_taken[0]);
    $display("  PC 0x%0h: predict_taken[1] = %0b", fetch_2_pred.PC[1], predict_taken[1]);
  endtask

  initial begin
    clock = 0;
    reset = 1;
    fetch_2_pred = '{default:32'h0};
    ret_2_pred = '{default:'0};

    @(negedge clock);
    reset = 0;

    // === Manually stepped simulation ===
    // Repeating fetch PCs: 0x10 and 0x20
    // Always taken, so predictor should eventually learn

    // Cycle 0
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b00, taken: 2'b00, PC: '{32'h0, 32'h0}};
    @(negedge clock); show_predictions("0");

    // Cycle 1
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b00, taken: 2'b00, PC: '{32'h0, 32'h0}};
    @(negedge clock); show_predictions("1");

    // Cycle 2
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("2");

    // Cycle 3
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("3");

    // Cycle 4
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("4");

    // Cycle 5
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("5");

    // Cycle 6
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("6");

    // Cycle 7
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("7");

    // Cycle 8
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("8");

    // Cycle 9
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("9");

    // Final cycle — check both predictions are taken
    if (predict_taken !== 2'b11)
      $fatal("❌ Final predictions should be TAKEN for both! Got %b", predict_taken);
    else
      $display("✅ Predictor correctly trained and returned TAKEN for both branches.");


     // Cycle 10
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("10");

     // Cycle 11
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("11");

     // Cycle 12
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("12");

     // Cycle 13
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("13");

     // Cycle 14
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("14");

     // Cycle 15
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("15");

     // Cycle 16
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("16");

     // Cycle 17
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("17");

     // Cycle 18
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("18");

     // Cycle 19
    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b11, taken: 2'b00, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("19");
    


    if (predict_taken !== 2'b00)
      $fatal("❌ Final predictions should be NOT TAKEN for both! Got %b", predict_taken);
    else
      $display("✅ Predictor correctly trained and returned NOT TAKEN for both branches.");

    /*fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("20");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("21");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("22");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("23");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("24");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("25");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("26");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("27");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("28");

    fetch_2_pred.PC[0] = 32'h10;
    fetch_2_pred.PC[1] = 32'h20;
    ret_2_pred = '{update_enable: 2'b01, taken: 2'b11, PC: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("29");*/



    $finish;
  end

endmodule
