// Simple FIFO with parametrizable depth and width
/*
min: clock period:
make -B syn CLOCK_PERIOD=1.9
*/

`include "sys_defs.svh"

typedef struct packed {
    INST inst;
    // logic [4:0] rob_num;
    logic [5:0] tag;
    logic [5:0] t_old;
} robItem;

module FIFO #(
    parameter DEPTH = 32, // num elements
    parameter WIDTH = $bits(robItem);//32, // num bits per element
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
    output logic [CNT_BITS-1:0] spots,
    output logic                full
);

    logic [$clog2(DEPTH)-1:0] head, next_head, old_head;
    logic [$clog2(DEPTH)-1:0] tail, next_tail;
    logic exception;

    memDP #(
        .WIDTH     (WIDTH),
        .DEPTH     (DEPTH),
        .READ_PORTS(1),
        .BYPASS_EN (0))
    fifo_mem (
        .clock  (clock),
        .reset  (reset),

        .re     (rd_valid),
        .raddr  (head),
        .rdata  (rd_data),

        .we     (wr_valid),
        .waddr  (tail),
        .wdata  (wr_data)
    );

    logic [$clog2(DEPTH):0] cnt, next_cnt, free;

    logic empty;
    assign empty    = cnt == '0;
    assign full     = cnt == DEPTH;
    assign spots     = DEPTH - cnt;
    assign old_head  = next_ex ? old_head : head;

    always_comb begin
        next_ex     = err || (old_head != head);

        rd_valid    = next_ex ? 1 : (rd_en && !empty);
        next_head   = next_ex ? head - 1 : (next_ex ? tail : (rd_valid ? (head + 1) % DEPTH : head));

        wr_valid    = wr_en && (!full || rd_valid);
        next_tail   = next_ex ? tail - 1 : (wr_valid ? (tail + 1) % DEPTH : tail);

        next_cnt    = cnt + wr_valid - rd_valid;
    end


    always_ff @(posedge clock) begin
        if (reset) begin
            cnt  <= '0;
            head <= '0;
            tail <= '0;
            exception <= '0;
        end else begin
            cnt  <= next_cnt;
            head <= next_head;
            tail <= next_tail;
            exception <= next_ex;
        end
    end

endmodule


module rob #(
    parameter DEPTH = 32, // num elements
    parameter WIDTH = 44, // num bits per element 
                          //(32 bits per insn + log2(64) = 6 bits each for T & Told)
    localparam CNT_BITS = $clog2(WIDTH)
) (
    input                       clock, 
    input                       reset,
    input                       dispatch_en,
    input                       retire_en,
    input                       err,
    input           [WIDTH-1:0] next_insn,
    output logic                wr_valid,
    output logic                rd_valid,
    output logic    [WIDTH-1:0] completed_insn,
    output logic [CNT_BITS-1:0] free_spots,
    output logic                full
);

    FIFO myfifo (
        .clock(clock), 
        .reset(reset), 
        .wr_en(insn_dispatch), 
        .rd_en(insn_retire), 
        .wr_data(next_insn), 
        .wr_valid(wr_valid), 
        .rd_valid(rd_valid), 
        .rd_data(completed_insn), 
        .spots(free_spots), 
        .full(full)
    );



endmodule