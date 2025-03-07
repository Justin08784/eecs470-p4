// FIFO module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh
`include "sys_defs.svh"
`include "test/fifo_sva.svh"

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

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end
    // Generate random numbers for our write data on each cycle
    always @(negedge clock) begin
        std::randomize(wr_data);
    end
    
    // FIFO instance
    fifo #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .NUM_RPORTS(NUM_RPORTS),
        .NUM_WPORTS(NUM_WPORTS),
        .MAX_SCNT(MAX_SCNT),
        .RESET_STATE('{default:0})
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

    fifo_sva #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .NUM_RPORTS(NUM_RPORTS),
        .NUM_WPORTS(NUM_WPORTS),
        .MAX_SCNT(MAX_SCNT)
    ) sva (
        .clock      (clock),
        .reset      (reset),
        .wr_en_cnt  (wr_en_cnt),
        .wr_data    (wr_data),
        .rd_en_cnt  (rd_en_cnt),
        .rd_data    (rd_data),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    initial begin
        $display("\nStart Testbench");
        clock = 0;
        reset = 1;
        wr_en_cnt = 0;
        rd_en_cnt = 0;

        $monitor("  %3d | d_in: %b   wr_en_cnt: %d  rd_en_cnt: %d  |  d_out: %b   used_scnt: %2d  free_scnt: %2d",
            $time,
            wr_data,
            wr_en_cnt,
            rd_en_cnt,
            rd_data, 
            used_scnt, 
            free_scnt);

        @(negedge clock);
        reset = 0;
        @(negedge clock);

        // ---------- Test 1 ---------- //
        // $display("\nTest 1: invalid read");
        // rd_en_cnt = 1;
        // @(negedge clock);
        // rd_en_cnt = 0;

        // ---------- Test 2 ---------- //
        $display("\nTest 2: Write and read with one cycle wait");
        $display("Write 1 value");
        wr_en_cnt = 1;
        @(negedge clock);
        wr_en_cnt = 0;

        $display("Wait one cycle");
        @(negedge clock);

        rd_en_cnt = 1;
        $display("Read 1 value");
        @(negedge clock);
        rd_en_cnt = 0;

        // ---------- Test 2.5 ---------- //
        $display("\nTest 2.5: Write and read twice with one cycle wait");
        $display("Write 1 value");
        wr_en_cnt = 2;
        @(negedge clock);
        wr_en_cnt = 0;

        $display("Wait one cycle");
        @(negedge clock);

        rd_en_cnt = 2;
        $display("Read 1 value");
        @(negedge clock);
        rd_en_cnt = 0;

        // ---------- Test 3 ---------- //
        $display("\nTest 3: Write and read with no wait");
        $display("Write 1 value");
        wr_en_cnt = 1;
        @(negedge clock);
        wr_en_cnt = 0;

        rd_en_cnt = 1;
        $display("Read 1 value");
        @(negedge clock);
        rd_en_cnt = 0;

        // ---------- Test 3.5 ---------- //
        $display("\nTest 3.5: Write and read twice with no wait");
        $display("Write 2 values");
        wr_en_cnt = 2;
        @(negedge clock);
        wr_en_cnt = 0;

        rd_en_cnt = 2;
        $display("Read 2 values");
        @(negedge clock);

        // ---------- Test -3 ---------- //
        $display("\nTest -3: Same-cycle write and read");
        wr_en_cnt = 1;
        rd_en_cnt = 1;
        @(negedge clock);
        wr_en_cnt = 0;
        rd_en_cnt = 0;

        // ---------- Test -3.5 ---------- //
        $display("\nTest -3.5: Same-cycle writes and reads each (2 of each)");
        $display("Write 2 values");
        wr_en_cnt = 2;
        rd_en_cnt = 2;
        @(negedge clock);
        wr_en_cnt = 0;
        rd_en_cnt = 0;

        // // ---------- Test 4 ---------- //
        // $display("\nTest 4: Read and write when empty");
        // wr_en_cnt = 2'b11;
        // rd_en_cnt = 2'b11;
        // @(negedge clock);
        // rd_en_cnt = 2'b00;

        // // ---------- Test 5 ---------- //
        // $display("\nTest 5: Write 6 values");
        // wr_en_cnt = 2'b11;
        // repeat (2) @(negedge clock);
        // wr_en_cnt = 2'b10;
        // @(negedge clock);
        // wr_en_cnt = 2'b01;
        // @(negedge clock);
        // wr_en_cnt = 2'b00;

        // // ---------- Test 6 ---------- //
        // $display("\nTest 6: Read 4 values");
        // rd_en_cnt = 2'b11;
        // @(negedge clock);
        // rd_en_cnt = 2'b10;
        // @(negedge clock);
        // rd_en_cnt = 2'b01;
        // @(negedge clock);
        // rd_en_cnt = 2'b00;

        // // ---------- Test 7 ---------- //
        // $display("\nTest 7: Write until full");
        // cnt = 2;
        // wr_en_cnt = 2'b11;
        // while (!full) begin
        //     cnt += 2;
        //     @(negedge clock);
        // end

        // // ---------- Test 8 ---------- //
        // $display("\nTest 8: Invalid write");
        // wr_en_cnt = 2'b11;
        // @(negedge clock);

        // // ---------- Test 9 ---------- //
        // $display("\nTest 9: Simultaneous read and write when full");
        // rd_en_cnt = 2'b11;
        // @(negedge clock);
        // wr_en_cnt = 2'b00;
        // rd_en_cnt = 2'b00;
        // @(negedge clock);

        // // ---------- Test 10 ---------- //
        // $display("\nTest 10: Write when one less than full");
        // rd_en_cnt = 2'b01;
        // $display("Read one");
        // @(negedge clock);
        // $display("Write two");
        // wr_en_cnt = 2'b11;
        // rd_en_cnt = 2'b00;
        // @(negedge clock);
        // $display("Read another one");
        // rd_en_cnt = 2'b10;
        // @(negedge clock);
        // wr_en_cnt = 2'b00;
        // rd_en_cnt = 2'b00;
        // @(negedge clock);

        // // ---------- Test 11 ---------- //
        // $display("\nTest 11: Read all values");
        // rd_en_cnt = 2'b11;
        // while (cnt > 0) begin
        //     cnt -= 2;
        //     @(negedge clock);
        // end

        // // ---------- Test 12 ---------- //
        // $display("\nTest 12: Invalid read");
        // rd_en_cnt = 2'b11;
        // @(negedge clock);
        // rd_en_cnt = 2'b00;

        // // ---------- Test 13 ---------- //
        // $display("\nTest 13: Four simultaneous reads and writes");
        // rd_en_cnt = 2'b10;
        // wr_en_cnt = 2'b01;
        // repeat (4) @(negedge clock);
        // wr_en_cnt = 2'b00;

        // // ---------- Test 14 ---------- //
        // $display("\nTest 14: Read last item");
        // @(negedge clock);
        // rd_en_cnt = 2'b00;

        // @(negedge clock);
        // @(negedge clock);

        // $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
