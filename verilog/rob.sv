// Simple FIFO with parametrizable depth and width
/*
min: clock period:
make -B syn CLOCK_PERIOD=1.9
*/

`include "sys_defs.svh"


module rob #(
    parameter DEPTH = `ROB_SZ,  // num elements
    parameter WIDTH = $bits(robItem),  // num bits per element 
                           //(32 bits per insn + log2(64) = 6 bits each for T & Told)
    localparam CNT_BITS = $clog2(DEPTH)
) (
    input                     clock,
    input                     reset,
    input  [1:0]              dispatch_en,
    input  [1:0]              retire_en,
    input                     err,
    input  [1:0] [ WIDTH-1:0] next_insn,
    output logic [1:0]        wr_valid,
    output logic [1:0]        rd_valid,
    output logic [1:0] [ WIDTH-1:0] completed_insn,
    output logic [CNT_BITS:0] free_spots,
    output logic              full
);

  

  FIFO myfifo (
      .clock(clock),
      .reset(reset),
      .wr_en(dispatch_en),
      .rd_en(retire_en),
      .err(err),
      .wr_data(next_insn),
      .wr_valid(wr_valid),
      .rd_valid(rd_valid),
      .rd_data(completed_insn),
      .spots(free_spots),
      .full(full)
  );
endmodule
