// SystemVerilog Assertions (SVA) for use with our FIFO module
// This file is included by the testbench to separate our main module checking code
// SVA are relatively new to 470, feel free to use them in the final project if you like

`ifndef ROB_SVA_SVH
`define ROB_SVA_SVH

module rob_sva #(
    parameter DEPTH = 32,
    parameter WIDTH = 44,
    //parameter MAX_CNT = 3,
    localparam CNT_BITS = $clog2(DEPTH)
) (
    input              clock, reset
    // input        [1:0] wr_en,
    // input [1:0] [WIDTH-1:0] wr_data,
    // input        [1:0] rd_en,
    // input [1:0] [WIDTH-1:0] rd_data,
    // input        [1:0] rd_valid,
    // input        [1:0] wr_valid,
    // input [CNT_BITS:0] spots,
    // input              full
);
    initial begin
    end

  // logic [$clog2(DEPTH+1)-1:0] entries;  // how full the buffer should be
  // int                         rd_count;  // number of reads complete

  // logic rd_valid_c1, rd_valid_c2, wr_valid_c1, wr_valid_c2;

  // assign rd_valid_c1 = rd_en[0] && (entries != 0);
  // assign rd_valid_c2 = rd_en[1] && (entries != 0);
  // assign wr_valid_c1 = wr_en[0] && (entries != DEPTH || rd_en[0]);
  // assign wr_valid_c2 = wr_en[1] && ((entries != DEPTH && entries != DEPTH-1) || rd_en[1]);

  // always_ff @(posedge clock) begin
  //   if (reset) begin
  //     entries  <= 0;
  //     rd_count <= 0;
  //   end else begin
  //     entries <= entries +
  //                      (wr_en[0] && entries != DEPTH ? 1-rd_valid_c1 : 0) +
  //                      (wr_en[1] && entries != DEPTH && entries != DEPTH-1 ? 1-rd_valid_c2 : 0) -
  //                      (rd_en[0] && entries != 0    ? 1-wr_valid_c1 : 0) -
  //                      (rd_en[1] && entries != 0    ? 1-wr_valid_c2 : 0);
  //     rd_count <= rd_valid[0] || rd_valid[1] ? (rd_valid[0] ^ rd_valid[1] ? rd_count + 1 : rd_count + 2) : rd_count;
  //   end
  // end

  // task exit_on_error;
  //   begin
  //     $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
  //     $finish;
  //   end
  // endtask

  // clocking cb @(posedge clock);
  //   // rd_valid asserted if and only if rd_en=1 and there is valid data
  //   property rd_valid_correct1;
  //     rd_valid_c1 iff rd_valid[0];
  //   endproperty

  //   property rd_valid_correct2;
  //     rd_valid_c2 iff rd_valid[1];
  //   endproperty

  //   // wr_valid asserted if and only if wr_en=1 and buffer not full
  //   property wr_valid_correct1;
  //     wr_valid_c1 iff wr_valid[0];
  //   endproperty

  //   property wr_valid_correct2;
  //     wr_valid_c2 iff wr_valid[1];
  //   endproperty

  //   // full asserted if and only if buffer is full
  //   property full_correct;
  //     full iff entries == DEPTH;
  //   endproperty

  //   // almost full signal asserted when there are ALERT_DEPTH entries left
  //   property spots_correct;
  //     disable iff (reset) spots == DEPTH - entries;
  //   endproperty

  //   // Check that data written in comes out after proper number of reads
  //   // NOTE: this property isn't used in verification as it runs slowly
  //   //      However, feel free to reference as an example of a more
  //   //      complex assertion
  //   property write_read_correctly1;
  //     logic [WIDTH-1:0] data_in
  //     ;
  //     int idx;
  //     (wr_valid[0],
  //     data_in = wr_data[0]
  //     ,
  //     idx = (rd_count + entries)
  //     )  // value is written
  //     ##[1:$] (rd_valid[0] && rd_count == idx)  // wait for previous entries to be read
  //     |-> rd_data[0] === data_in;  // ensure correct value out
  //   endproperty

  //   property write_read_correctly2;
  //     logic [WIDTH-1:0] data_in
  //     ;
  //     int idx;
  //     (wr_valid[1],
  //     data_in = wr_data[1]
  //     ,
  //     idx = (rd_count + entries)
  //     )  // value is written
  //     ##[1:$] (rd_valid[1] && rd_count == idx)  // wait for previous entries to be read
  //     |-> rd_data[1] === data_in;  // ensure correct value out
  //   endproperty

  //   property rd_valid_live1;
  //     rd_en[0] |-> s_eventually rd_valid[0];
  //   endproperty

  //   property rd_valid_live2;
  //     rd_en[1] |-> s_eventually rd_valid[1];
  //   endproperty

  //   property wr_valid_live1;
  //     wr_en[0] |-> s_eventually wr_valid[0];
  //   endproperty

  //   property wr_valid_live2;
  //     wr_en[1] |-> s_eventually wr_valid[1];
  //   endproperty

  // endclocking

  // // Assert properties
  // ValidRd1 :
  // assert property (cb.rd_valid_correct1)
  // else exit_on_error;
  // ValidRd2 :
  // assert property (cb.rd_valid_correct2)
  // else exit_on_error;
  // ValidWr1 :
  // assert property (cb.wr_valid_correct1)
  // else exit_on_error;
  // ValidWr2 :
  // assert property (cb.wr_valid_correct2)
  // else exit_on_error;
  // ValidFull :
  // assert property (cb.full_correct)
  // else exit_on_error;
  // ValidSpots :
  // assert property (cb.spots_correct)
  // else exit_on_error;

  // // Liveness checks
  // RdValidLiveness1 :
  // assert property (cb.rd_valid_live1)
  // else exit_on_error;
  // RdValidLiveness2 :
  // assert property (cb.rd_valid_live2)
  // else exit_on_error;
  // WrValidLiveness1 :
  // assert property (cb.wr_valid_live1)
  // else exit_on_error;
  // WrValidLiveness2 :
  // assert property (cb.wr_valid_live2)
  // else exit_on_error;

  // // This assertion is large and slow for formal verification, 
  // // but it works for a testbench
  // DataOutErr1 :
  // assert property (cb.write_read_correctly1)
  // else exit_on_error;
  // DataOutErr2 :
  // assert property (cb.write_read_correctly2)
  // else exit_on_error;

  // genvar i;
  // generate
  //   for (i = 0; i < WIDTH; i++) begin
  //     cov_bit_i :
  //     cover property (@(posedge clock) wr_data[0][i]);
  //     cover property (@(posedge clock) wr_data[1][i]);
  //   end
  // endgenerate


endmodule

`endif  // ROB_SVA_SVH
