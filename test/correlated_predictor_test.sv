`include "sys_defs.svh"

module correlated_predictor_tb;

  parameter N = 2;

  logic clock, reset;

  fetch2predictor    fetch_2_pred;
  //retire2predictor   ret_2_pred;
  predictor2fetch    pred_2_fetch;

  correlated_predictor dut (
    .clock(clock),
    .reset(reset),
    .fetch_in(fetch_2_pred),
    //.ret_2_pred(ret_2_pred),
    .pred_out(pred_2_fetch)
  );

  // Clock generation
  always #5 clock = ~clock;
  // Helper macros
  task show_predictions(string label);
    $display("Cycle %s:", label);
    $display("  PC 0x%0h: prediction[0] = %0b fetch_2_pred.taken[0] = %1b", fetch_2_pred.PC[0], pred_2_fetch.prediction[0], fetch_2_pred.taken[0]);
    $display("  PC 0x%0h: prediction[1] = %0b fetch_2_pred.taken[1] = %1b", fetch_2_pred.PC[1], pred_2_fetch.prediction[1], fetch_2_pred.taken[1]);
  endtask

  initial begin
    clock = 0;
    reset = 1;
    //fetch_2_pred = '{default:32'h0};
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b00, taken: 2'b00, correct_PC: '{32'h0, 32'h0}, retired_bhr: '{8'b00000000, 8'b00000000}, correlated_bhr: '{8'b00000000, 8'b00000000}};
    //ret_2_pred = '{default:'0};

    @(negedge clock);
    reset = 0;

    // === Manually stepped simulation ===
    // Repeating fetch PCs: 0x10 and 0x20
    // Always taken, so predictor should eventually learn

    // Cycle 0
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h0, 32'h0}, retired_bhr: '{8'b00000000, 8'b00000000}, correlated_bhr: '{8'b00000000, 8'b00000000}};
    @(negedge clock); show_predictions("0");

    // Cycle 1
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h0, 32'h0}, retired_bhr: '{8'b00000001, 8'b00000001}, correlated_bhr: '{8'b00000001, 8'b00000001}};
    @(negedge clock); show_predictions("1");

    // Cycle 2
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b00000011, 8'b00000011}, correlated_bhr: '{8'b00000011, 8'b00000011}};
    @(negedge clock); show_predictions("2");

    // Cycle 3
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b00000111, 8'b00000111}, correlated_bhr: '{8'b00000111, 8'b00000111}};
    @(negedge clock); show_predictions("3");

    // Cycle 4
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b00001111, 8'b00001111}, correlated_bhr: '{8'b00001111, 8'b00001111}};
    @(negedge clock); show_predictions("4");

    // Cycle 5
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b00011111, 8'b00011111}, correlated_bhr: '{8'b00011111, 8'b00011111}};
    @(negedge clock); show_predictions("5");
 
    // Cycle 6
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b00111111, 8'b00111111}, correlated_bhr: '{8'b00111111, 8'b00111111}};
    @(negedge clock); show_predictions("6");

    // Cycle 7
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b01111111, 8'b01111111}, correlated_bhr: '{8'b00111111, 8'b00111111}};
    @(negedge clock); show_predictions("7");

    // Cycle 8
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b11111111, 8'b11111111}, correlated_bhr: '{8'b01111111, 8'b01111111}};
    @(negedge clock); show_predictions("8");

    // Cycle 9
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b11111111, 8'b11111111}, correlated_bhr: '{8'b11111111, 8'b11111111}};
    @(negedge clock); show_predictions("9");

    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b11111111, 8'b11111111}, correlated_bhr: '{8'b11111111, 8'b11111111}};
    @(negedge clock); show_predictions("10");

    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b11111111, 8'b11111111}, correlated_bhr: '{8'b11111111, 8'b11111111}};
    @(negedge clock); show_predictions("11");

    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{8'b11111111, 8'b11111111}, correlated_bhr: '{8'b11111111, 8'b11111111}};
    @(negedge clock); show_predictions("12");

    // Final cycle — check both predictions are taken
    if (pred_2_fetch.prediction != 2'b11)
      $fatal("❌ Final predictions should be TAKEN for both! Got %b", pred_2_fetch.prediction);
    else
      $display("✅ Predictor correctly trained and returned TAKEN for both branches.");


     // Cycle 10
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
   /* fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("10");

     // Cycle 11
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("11");

     // Cycle 12
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("12");

     // Cycle 13
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("13");

     // Cycle 14
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("14");

     // Cycle 15
   // fetch_2_pred.PC[0] = 32'h10;
   // fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("15");

     // Cycle 16
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("16");

     // Cycle 17
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("17");

     // Cycle 18
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("18");

     // Cycle 19
    //fetch_2_pred.PC[0] = 32'h10;
    //fetch_2_pred.PC[1] = 32'h20;
    fetch_2_pred = '{PC: '{32'h10,32'h20}, update_enable: 2'b11, taken: 2'b11, correct_PC: '{32'h10, 32'h20}, retired_bhr: '{32'h10, 32'h20}};
    @(negedge clock); show_predictions("19");
    


    if (pred_2_fetch.prediction != 2'b11)
      $fatal("❌ Final predictions should be NOT TAKEN for both! Got %b", pred_2_fetch.prediction);
    else
      $display("✅ Predictor correctly trained and returned NOT TAKEN for both branches.");*/

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
