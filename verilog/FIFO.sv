`include "sys_defs.svh"

module FIFO #(
    parameter DEPTH = `ROB_SZ, // num elements
    parameter WIDTH = $bits(ROB_ENTRY),//32, // num bits per element
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
