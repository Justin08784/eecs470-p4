// Simple FIFO with parametrizable depth and width
/*
min: clock period:
make -B syn CLOCK_PERIOD=1.9
*/

`include "sys_defs.svh"

typedef struct packed {
  INST inst;
  // logic [4:0] rob_num;
  logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] tag;
  logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] t_old;
} robItem;

module FIFO #(
    parameter DEPTH = `ROB_SZ, // num elements
    parameter WIDTH = $bits(robItem),//32, // num bits per element
    localparam CNT_BITS = $clog2(DEPTH)
) (
    input                       clock, 
    input                       reset,
    input     [1:0]             wr_en,
    input     [1:0]             rd_en,
    input     [1:0] [WIDTH-1:0] wr_data,
    input                       err,
    output logic [1:0]          wr_valid,
    output logic [1:0]          rd_valid,
    output logic [1:0] [WIDTH-1:0] rd_data,
    output logic   [CNT_BITS:0] spots,
    output logic                full
);

    logic [$clog2(DEPTH)-1:0] head, next_head;
    logic [$clog2(DEPTH)-1:0] tail, next_tail;
    logic [DEPTH-1:0] [WIDTH-1:0] buffer;
    logic [$clog2(DEPTH):0] cnt, next_cnt;
    logic empty;
    logic [1:0] [WIDTH-1:0] next_rd_data;
    //logic head_overwritten;

    assign empty    = cnt == '0;
    assign full     = cnt == DEPTH;
    assign spots     = DEPTH - cnt;

    always_comb begin
        rd_data[0] = buffer[head];
        rd_data[1] = buffer[head+1];

        rd_valid[0] = rd_en[0] && !empty;
        rd_valid[1] = rd_en[1] && !empty;
        next_head   = rd_valid[0] || rd_valid[1] ? (rd_valid[0] ^ rd_valid[1] ? (head + 1) % DEPTH : (head + 2) % DEPTH) : head;

        wr_valid[0] = wr_en[0] && (!full || rd_valid[0]);
        wr_valid[1] = spots == 1 ? '0 : (wr_en[1] && (!full || rd_valid[1]));
        next_tail   = wr_valid[0] || wr_valid[1] ? (wr_valid[0] ^ wr_valid[1] ? (tail + 1) % DEPTH : (tail + 2) % DEPTH) : tail;

        next_cnt    = cnt + wr_valid[0] + wr_valid[1] - rd_valid[0] - rd_valid[1];

        if(rd_valid[0] || rd_valid[1]) begin
          rd_data[0] = buffer[head];
        end
        if(rd_valid[0] && rd_valid[1]) begin
          rd_data[1] = buffer[head+1];
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

            if(wr_valid[0] || wr_valid[1]) begin
                buffer[tail] <= wr_data[0];
            end
            if(wr_valid[0] && wr_valid[1]) begin
                buffer[tail+1] <= wr_data[1];
            end
        end
    end

endmodule


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
