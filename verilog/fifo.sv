`include "sys_defs.svh"

module fifo #(
    parameter int unsigned DEPTH=`ROB_SZ,       // num elements
    parameter int unsigned WIDTH=$bits(PHYS_REG_IDX),       // num bits per element
    type FIFO_STATE = struct packed {
        logic [$clog2(DEPTH)-1:0] head;
        logic [$clog2(DEPTH)-1:0] tail;
        logic [DEPTH-1:0][WIDTH-1:0] state;
        logic [$clog2(DEPTH):0]   used;
        // logic [$clog2(DEPTH):0]   free;
    },
    parameter int unsigned NUM_RPORTS=`N, // also cap for used_scnt
    parameter int unsigned NUM_WPORTS=`N, // also cap for free_scnt
    parameter FIFO_STATE RESET_STATE='{default:0}
) (
    input                                           clock, 
    input                                           reset,

    input   logic   [$clog2(NUM_WPORTS):0]          wr_en_cnt,
    input   logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data,

    input   logic   [$clog2(NUM_RPORTS):0]          rd_en_cnt,
    output  logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data,

    output  logic   [$clog2(NUM_WPORTS):0]          free_scnt,
    output  logic   [$clog2(NUM_RPORTS):0]          used_scnt

    /*NOTE: By removing rd_valid, wr_valid, we force the caller to make sure
    the enabled cnts are correct. */
);
    logic [$clog2(DEPTH)-1:0]       head;
    logic [$clog2(DEPTH)-1:0]       tail;
    logic [DEPTH-1:0][WIDTH-1:0]    state;
    logic [$clog2(DEPTH):0]         used, free;

    logic [NUM_RPORTS-1:0][$clog2(DEPTH)-1:0] rd_idxs;
    logic [NUM_WPORTS-1:0][$clog2(DEPTH)-1:0] wr_idxs;

    assign free         = DEPTH - used;
    assign free_scnt    = free > NUM_WPORTS ? NUM_WPORTS : free;
    assign used_scnt    = used > NUM_RPORTS ? NUM_RPORTS : used;

    // Version 1:
    // always_comb begin
    //     for (int unsigned i = 0; i < NUM_RPORTS; ++i)
    //         rd_idxs[i] = (head + i) % DEPTH;
    //     for (int unsigned i = 0; i < NUM_WPORTS; ++i)
    //         wr_idxs[i] = (tail + i) % DEPTH;


    //     rd_data = '0;
    //     // fwd if read matches a write; last write wins
    //     for (int unsigned i = 0; i < NUM_RPORTS; ++i) begin
    //         if (i >= rd_en_cnt) // suppresses oob index warning
    //             continue;
    //         rd_data[i] = state[rd_idxs[i]];
    //         for (int unsigned j = 0; j < NUM_WPORTS; ++j) begin
    //             if (j >= wr_en_cnt || rd_idxs[i] != wr_idxs[j]) // j >= ... suppresses oob index warning
    //                 continue;
    //             rd_data[i] = wr_data[j];
    //         end
    //     end
    // end

    // Version 2:
    logic [NUM_RPORTS-1:0] fwd_dat;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            rd_idxs[i] = (head + i) % DEPTH;
        for (int unsigned i = 0; i < NUM_WPORTS; ++i)
            wr_idxs[i] = (tail + i) % DEPTH;
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            fwd_dat[i] = i >= used;

        // fwding logic
        for (int unsigned i = 0; i < NUM_RPORTS; ++i) begin
            if (i >= rd_en_cnt) begin
                rd_data[i] = '0;
            end else if (fwd_dat[i] && (i - used) < wr_en_cnt) begin
                rd_data[i] = wr_data[i - used];
            end else begin
                rd_data[i] = state[rd_idxs[i]];
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            used    <= RESET_STATE.used;
            head    <= RESET_STATE.head;
            tail    <= RESET_STATE.tail;
            state   <= RESET_STATE.state;
        end else begin
            if (wr_en_cnt > free + rd_en_cnt)
                $error("FIFO overflow!");
            if (rd_en_cnt > used + wr_en_cnt)
                $error("FIFO underflow!");
            used    <= used + wr_en_cnt - rd_en_cnt;
            head    <= (head + rd_en_cnt) % DEPTH;
            tail    <= (tail + wr_en_cnt) % DEPTH;
            for (int unsigned i = 0; i < NUM_WPORTS; ++i) begin
                if (i >= wr_en_cnt) // suppresses oob index warning
                    continue;
                state[wr_idxs[i]] <= wr_data[i];
            end
        end
    end
endmodule