`include "sys_defs.svh"

module fifo #(parameter
    DEPTH=44,       // num elements
    WIDTH=32,       // num bits per element
    NUM_RPORTS=`N,
    NUM_WPORTS=`N,
    MAX_SCNT=`N,    // should be less than DEPTH
    logic [DEPTH-1:0][WIDTH-1:0] RESET_STATE = '0
) (
    input                                           clock, 
    input                                           reset,

    input   logic   [$clog2(NUM_WPORTS):0]          wr_en_cnt,
    input   logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data,

    input   logic   [$clog2(NUM_RPORTS):0]          rd_en_cnt,
    output  logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data,

    output  logic   [$clog2(MAX_SCNT):0]            free_scnt,
    output  logic   [$clog2(MAX_SCNT):0]            used_scnt

    /*NOTE: By removing rd_valid, wr_valid, we force the caller to make sure
    the enabled cnts are correct. */
);
    logic [$clog2(DEPTH)-1:0] head;
    logic [$clog2(DEPTH)-1:0] tail;
    logic [DEPTH-1:0][WIDTH-1:0] state;
    logic [$clog2(DEPTH):0]   used, free;

    logic [NUM_RPORTS-1:0][$clog2(DEPTH)-1:0] rd_idxs;
    logic [NUM_WPORTS-1:0][$clog2(DEPTH)-1:0] wr_idxs;

    assign free         = DEPTH - used;
    assign free_scnt    = free > MAX_SCNT ? MAX_SCNT : free;
    assign used_scnt    = used > MAX_SCNT ? MAX_SCNT : used;

    always_comb begin
        foreach (rd_idxs[i])
            rd_idxs[i] = (head + i) % DEPTH;
        foreach (wr_idxs[i])
            wr_idxs[i] = (tail + i) % DEPTH;

        rd_data = '0;
        // fwd if read matches a write; last write wins
        for (int i = 0; i < rd_en_cnt; ++i) begin
            rd_data[i] = state[rd_idxs[i]];
            for (int j = 0; j < wr_en_cnt; ++j) begin
                if (rd_idxs[i] != wr_idxs[j])
                    continue;
                rd_data[i] = wr_data[j];
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            used    <= '0;
            head    <= '0;
            tail    <= '0;
            state   <= RESET_STATE;
        end else begin
            if (wr_en_cnt > free)
                $error("FIFO overflow!");
            if (rd_en_cnt > used)
                $error("FIFO underflow!");
            used    <= used + wr_en_cnt - rd_en_cnt;
            head    <= (head + rd_en_cnt) % DEPTH;
            tail    <= (tail + wr_en_cnt) % DEPTH;
            for (int i = 0; i < wr_en_cnt; ++i) begin
                state[wr_idxs[i]] <= wr_data[i];
            end
        end
    end
endmodule

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
