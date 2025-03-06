// FIFO module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh
`include "sys_defs.svh"
// `include "test/fifo_sva.svh"

module fifo_test();
    localparam DEPTH = `ROB_SZ;
    localparam WIDTH = $bits(PHYS_REG_IDX);
    localparam NUM_RPORTS = 2;
    localparam NUM_WPORTS = 2;
    localparam MAX_SCNT   = 2;

    typedef struct packed {
        logic [$clog2(DEPTH)-1:0] head;
        logic [$clog2(DEPTH)-1:0] tail;
        logic [DEPTH-1:0][WIDTH-1:0] state;
        logic [$clog2(DEPTH):0]   used;
        // logic [$clog2(DEPTH):0]   free;
    } FIFO_STATE;
    function automatic FIFO_STATE gen_reset_state();
        logic [DEPTH-1:0][WIDTH-1:0] state;
        logic [WIDTH-1:0] start = 32;
        // `ROB_SZ = `PHYS_REG_SZ_R10K - 32
        for (int unsigned i = 0; i < $unsigned(DEPTH); ++i) begin
            state[i] = start + i;
        end
        return '{
            head:0,
            tail:0,
            state:state,
            used:DEPTH
        };
    endfunction
    localparam FIFO_STATE RESET_STATE = gen_reset_state();

    logic                               clock, reset;
    logic   [$clog2(NUM_WPORTS):0]      wr_en_cnt;
    logic   [NUM_WPORTS-1:0][WIDTH-1:0] wr_data;
    logic   [$clog2(NUM_RPORTS):0]      rd_en_cnt;
    logic   [NUM_RPORTS-1:0][WIDTH-1:0] rd_data;
    logic   [$clog2(MAX_SCNT):0]        free_scnt;
    logic   [$clog2(MAX_SCNT):0]        used_scnt;
    
    // Variable to count values written to FIFO
    int cnt;
    
    // FIFO instance
    fifo #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .NUM_RPORTS(NUM_RPORTS),
        .NUM_WPORTS(NUM_WPORTS),
        .MAX_SCNT(MAX_SCNT)
    ) dut (
        .clock      (clock),
        .reset      (reset),
        .wr_en_cnt  (wr_en_cnt),
        .wr_data    (wr_data),
        .rd_en_cnt  (rd_en_cnt),
        .rd_data    (rd_data),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );


endmodule
