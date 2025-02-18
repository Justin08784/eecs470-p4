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
    parameter DEPTH = 16, // num elements
    parameter WIDTH = $bits(robItem);//32, // num bits per element
    parameter MAX_CNT = 3,
    localparam CNT_BITS = $clog2(MAX_CNT+1)
) (
    input                       clock, 
    input                       reset,
    input                       wr_en,
    input                       rd_en,
    input           [WIDTH-1:0] wr_data,
    output logic                wr_valid,
    output logic                rd_valid,
    output logic    [WIDTH-1:0] rd_data,
    output logic [CNT_BITS-1:0] spots,
    output logic                full
);

    // LAB5 TODO: Make the FIFO, see other TODOs below
    // Some things you will need to do:
    // - Define the sizes for your head (read) and tail (write) pointer
    // - Increment the pointers when needed (hint: try using the modulo operator: '%')
    // - Write to the tail when wr_en == 1 and the fifo isn't full
    // - Read from the head when rd_en == 1 and the fifo isn't empty

    // LAB5 TODO: how wide is a pointer to DEPTH elements?
    logic [$clog2(DEPTH)-1:0] head, next_head;
    logic [$clog2(DEPTH)-1:0] tail, next_tail;

    // If you're using one-hot head and tail pointers, feel free to use your own
    // 2D flop array instead
    memDP #(
        .WIDTH     (WIDTH),
        .DEPTH     (DEPTH),
        .READ_PORTS(1),
        .BYPASS_EN (0))
    fifo_mem (
        // LAB 5 TODO: complete the port wiring for this module
        .clock  (clock),
        .reset  (reset),

        .re     (rd_valid),
        .raddr  (head),
        .rdata  (rd_data),

        .we     (wr_valid),
        .waddr  (tail),
        .wdata  (wr_data)
    );

    // LAB5 TODO: Use one of three ways to track if full/empty:
    //  1. (easiest) Keep a count of the number of entries
    //  2. (easy)    Make your memory 1 entry larger so head never equals tail
    //  2. (medium)  Use a valid bit for each entry
    //  3. (hardest) Use head == tail and keep a state of empty vs. full in always_ff

    // These have to be (log_2(D)) instead of (log_2(D)-1) so they can fit max value DEPTH.
    // This is because they are counts, unlike pointers like head and tail.
    logic [$clog2(DEPTH):0] cnt, next_cnt, free;

    // LAB5 TODO: Determine a way to calculate spots
    logic empty;
    assign empty    = cnt == '0;
    assign full     = cnt == DEPTH;
    // assign spots    = |cnt[$clog2(DEPTH)-1:CNT_BITS] ? '1 : cnt;
    assign free     = DEPTH - cnt;
    assign spots    = free > MAX_CNT ? MAX_CNT : free[CNT_BITS-1:0];

    always_comb begin
        rd_valid    = rd_en && !empty;
        next_head   = rd_valid ? (head + 1) % DEPTH : head;

        wr_valid    = wr_en && (!full || rd_valid);
        next_tail   = wr_valid ? (tail + 1) % DEPTH : tail;

        next_cnt    = cnt + wr_valid - rd_valid;
        // LAB5 TODO: Add logic for the next state
        // (also feel free to use assign statements)
    end


    always_ff @(posedge clock) begin
        if (reset) begin
            cnt  <= '0;
            head <= '0;
            tail <= '0;
            // LAB5 TODO: Initialize state variables
        end else begin
            cnt  <= next_cnt;
            head <= next_head;
            tail <= next_tail;
            // LAB5 TODO: Update on each cycle
        end
    end

endmodule


module rob #(
    parameter DEPTH = 16, // num elements
    parameter WIDTH = 32, // num bits per element
    parameter MAX_CNT = 3,
    localparam CNT_BITS = $clog2(MAX_CNT+1)
) (
    input                       clock, 
    input                       reset,
    input                       wr_en,
    input                       rd_en,
    input           [WIDTH-1:0] wr_data,
    output logic                wr_valid,
    output logic                rd_valid,
    //output logic    [WIDTH-1:0] rd_data,
    output logic [CNT_BITS-1:0] spots,
    output logic                full
);

FIFO myfifo (.clock(), .reset(), .wr_en(), .rd_en(), .wr_data(), .wr_valid(), .rd_valid(), .rd_data(), .spots(), .full());



endmodule