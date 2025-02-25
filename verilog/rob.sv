// Simple FIFO with parametrizable depth and width
/*
min: clock period:
make -B syn CLOCK_PERIOD=1.9
*/

`include "sys_defs.svh"

typedef struct packed {
  INST inst;
  // logic [4:0] rob_num;
  ADDR NPC;
  logic [5:0] tag;
  logic [5:0] t_old;
} robItem;

module FIFO #(
    parameter DEPTH = 32, // num elements
    parameter WIDTH = $bits(robItem),//32, // num bits per element
    localparam CNT_BITS = $clog2(DEPTH)
) (
    input                       clock, 
    input                       reset,
    input                       wr_en,
    input                       rd_en,
    input           [WIDTH-1:0] wr_data,
    input                       err,
    output logic                wr_valid,
    output logic                rd_valid,
    output logic    [WIDTH-1:0] rd_data,
    output logic [CNT_BITS:0] spots,
    output logic                full
);

    logic [$clog2(DEPTH)-1:0] head, next_head;
    logic [$clog2(DEPTH)-1:0] tail, next_tail;
    logic [DEPTH-1:0] [WIDTH-1:0] buffer;
    logic [$clog2(DEPTH):0] cnt, next_cnt;
    logic empty;
    //logic head_overwritten;

    assign empty    = cnt == '0;
    assign full     = cnt == DEPTH;
    assign spots     = DEPTH - cnt;

    always_comb begin
        rd_valid    = rd_en && !empty;
        next_head   = rd_valid ? (head + 1) % DEPTH : head;

        wr_valid    = wr_en && (!full || rd_valid);
        next_tail   = (wr_valid ? (tail + 1) % DEPTH : tail);

        next_cnt    = cnt + wr_valid - rd_valid;

        if(rd_valid) begin
          rd_data = buffer[head];
          //buffer[head] = '0;
          //head_overwritten = 0'b1;;
        end

    end

    always_ff @(posedge clock) begin
        if (reset) begin
            cnt  <= '0;
            head <= '0;
            tail <= '0;
        end else begin
            cnt  <= next_cnt;
            head <= next_head;
            tail <= next_tail;

            if(wr_valid) begin
            buffer[tail] <= wr_data;
            //next_tail = tail+1;
            end
        end
    end

endmodule


module rob #(
    parameter DEPTH = 32,  // num elements
    parameter WIDTH = $bits(robItem),  // num bits per element 
                           //(32 bits per insn + log2(64) = 6 bits each for T & Told)
    localparam CNT_BITS = $clog2(DEPTH)
) (
    input                     clock,
    input                     reset,
    input                     dispatch_en,
    input                     retire_en,
    input                     err,
    input        [ WIDTH-1:0] next_insn,
    output logic              wr_valid,
    output logic              rd_valid,
    output logic [ WIDTH-1:0] completed_insn,
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
