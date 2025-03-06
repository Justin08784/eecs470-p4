`include "sys_defs.svh"

module fifo #(parameter
    int unsigned DEPTH,       // num elements
    int unsigned WIDTH,       // num bits per element
    int unsigned NUM_RPORTS,
    int unsigned NUM_WPORTS,
    int unsigned MAX_SCNT,    // should be less than DEPTH
    logic [DEPTH-1:0][WIDTH-1:0] RESET_STATE
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
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            rd_idxs[i] = (head + i) % DEPTH;
        for (int unsigned i = 0; i < NUM_WPORTS; ++i)
            wr_idxs[i] = (tail + i) % DEPTH;


        rd_data = '0;
        // fwd if read matches a write; last write wins
        for (int unsigned i = 0; i < NUM_RPORTS; ++i) begin
            if (i >= rd_en_cnt) // suppresses oob index warning
                continue;
            rd_data[i] = state[rd_idxs[i]];
            for (int unsigned j = 0; j < NUM_WPORTS; ++j) begin
                if (j >= wr_en_cnt || rd_idxs[i] != wr_idxs[j]) // j >= ... suppresses oob index warning
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
            for (int unsigned i = 0; i < NUM_WPORTS; ++i) begin
                if (i >= wr_en_cnt) // suppresses oob index warning
                    continue;
                state[wr_idxs[i]] <= wr_data[i];
            end
        end
    end
endmodule