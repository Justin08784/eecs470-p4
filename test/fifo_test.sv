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
    logic   [$clog2(NUM_WPORTS):0]      free_scnt;
    logic   [$clog2(NUM_RPORTS):0]      used_scnt;
    logic   [$clog2(NUM_RPORTS):0]      prvw_vld_cnt;
    
    // Variable to count values written to FIFO
    int cnt;

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end
    // Generate nonzero random numbers for our write data on each cycle
    // (we shall treat a 0 as non-enabled; this allows us to print 0s in the $monitor
    // to indicate non-enabled)
    always @(negedge clock) begin
        std::randomize(wr_data) with {
            foreach(wr_data[i])
                wr_data[i] != 0;
        };
    end

    logic DEBUG = 1;
    always @(posedge clock) begin
        if (DEBUG) begin
            $display("  %3d | d_in: [%d, %d]   wr_en_cnt: %d  rd_en_cnt: %d  |  d_out: [%d, %d]   used_scnt: %2d  free_scnt: %2d  prvw_vld_cnt: %0d",
                $time,
                wr_en_cnt > 0 ? wr_data[0] : 0,
                wr_en_cnt > 1 ? wr_data[1] : 0,
                wr_en_cnt,
                rd_en_cnt,
                rd_data[0], 
                rd_data[1], 
                used_scnt, 
                free_scnt,
                prvw_vld_cnt);
        end
    end
    
    // FIFO instance
    fifo #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .NUM_RPORTS(NUM_RPORTS),
        .NUM_WPORTS(NUM_WPORTS),
        .ENABLE_INTR_FWD(`TRUE),
        .RESET_STATE('{default:0})
    ) dut (
        .clock      (clock),
        .reset      (reset),
        .wr_en_cnt  (wr_en_cnt),
        .wr_data    (wr_data),
        .rd_en_cnt  (rd_en_cnt),
        .rd_data    (rd_data),
        .free_scnt  (free_scnt),
        .prvw_vld_cnt(prvw_vld_cnt),
        .used_scnt  (used_scnt)
    );

    fifo_sva #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .NUM_RPORTS(NUM_RPORTS),
        .NUM_WPORTS(NUM_WPORTS)
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

        // $monitor("  %3d | d_in: [%d, %d]   wr_en_cnt: %d  rd_en_cnt: %d  |  d_out: [%d, %d]   used_scnt: %2d  free_scnt: %2d",
        //     $time,
        //     wr_en_cnt > 0 ? wr_data[0] : 0,
        //     wr_en_cnt > 1 ? wr_data[1] : 0,
        //     wr_en_cnt,
        //     rd_en_cnt,
        //     rd_data[0], 
        //     rd_data[1], 
        //     used_scnt, 
        //     free_scnt);

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

        // ---------- Test 4 ---------- //
        $display("\nTest 4: Read and write when empty");
        wr_en_cnt = 2;
        rd_en_cnt = 2;
        @(negedge clock);
        rd_en_cnt = 2'b00;

        // ---------- Test 5 ---------- //
        $display("\nTest 5: Write 6 values");
        wr_en_cnt = 2;
        repeat (2) @(negedge clock);
        wr_en_cnt = 1;
        @(negedge clock);
        wr_en_cnt = 1;
        @(negedge clock);
        wr_en_cnt = 0;

        // // ---------- Test 6 ---------- //
        $display("\nTest 6: Read 4 values");
        rd_en_cnt = 2;
        @(negedge clock);
        rd_en_cnt = 1;
        @(negedge clock);
        rd_en_cnt = 1;
        @(negedge clock);
        rd_en_cnt = 0;

        // ---------- Test 7 ---------- //
        $display("\nTest 7: Write until full");
        wr_en_cnt = 2;
        while (free_scnt) begin
            @(negedge clock);
        end
        wr_en_cnt = 0;

        // ---------- Test 8 ---------- //
        // $display("\nTest 8: Invalid write");
        // wr_en_cnt = 1;
        // @(negedge clock);

        // ---------- Test 9 ---------- //
        $display("\nTest 9: Simultaneous read and write when full");
        rd_en_cnt = 2;
        wr_en_cnt = 2;
        @(negedge clock);
        wr_en_cnt = 0;
        rd_en_cnt = 0;
        @(negedge clock);

        // ---------- Test 10 ---------- //
        $display("\nTest 10: Read and write when one less than full");
        $display("Read when full");
        rd_en_cnt = 1;
        @(negedge clock);
        $display("Read and write");
        wr_en_cnt = 1;
        @(negedge clock);
        wr_en_cnt = 0;
        rd_en_cnt = 0;
        @(negedge clock);

        // ---------- Test 11 ---------- //
        $display("\nTest 11: Read all values except 1");
        rd_en_cnt = 1;
        while (used_scnt > 1) begin
            @(negedge clock);
        end

        // // ---------- Test 12 ---------- //
        // $display("\nTest 12: Invalid read");
        // rd_en_cnt = 2'b11;
        // @(negedge clock);
        // rd_en_cnt = 2'b00;

        // ---------- Test 13 ---------- //
        $display("\nTest 13: Four simultaneous reads and writes when one more than empty");
        rd_en_cnt = 1;
        wr_en_cnt = 1;
        repeat (4) @(negedge clock);
        wr_en_cnt = 0;

        // ---------- Test 14 ---------- //
        $display("\nTest 14: Read last item");
        @(negedge clock);
        rd_en_cnt = 0;

        // ---------- Test 15 ---------- //
        $display("\nTest 15: Forwarding");

        $display("1 read: from state");
        wr_en_cnt = 1;
        @(negedge clock);
        wr_en_cnt = 0;

        rd_en_cnt = 1;
        @(negedge clock);
        rd_en_cnt = 0;

        $display("1 read: fwded");
        wr_en_cnt = 1;
        rd_en_cnt = 1;
        @(negedge clock);
        wr_en_cnt = 0;
        rd_en_cnt = 0;

        $display("2 reads: both from state");
        wr_en_cnt = 2;
        @(negedge clock);
        wr_en_cnt = 0;

        rd_en_cnt = 2;
        @(negedge clock);
        rd_en_cnt = 0;

        $display("2 reads: 1 from state, 1 fwded");
        wr_en_cnt = 1;
        @(negedge clock);

        rd_en_cnt = 2;
        @(negedge clock);
        wr_en_cnt = 0;
        rd_en_cnt = 0;

        $display("2 reads: both fwded");
        wr_en_cnt = 2;
        rd_en_cnt = 2;
        @(negedge clock);
        wr_en_cnt = 0;
        rd_en_cnt = 0;


        // ---------- Test 16 ---------- //
        $display("\nTest 16: Randomized stress testing");
        DEBUG = 0; // disable debugs
        for (int i = 0; i < 10000; ++i) begin
            if (free_scnt < NUM_WPORTS) begin
                wr_en_cnt = $urandom_range(`MIN(NUM_WPORTS, free_scnt + NUM_RPORTS), 0);
            end else begin
                wr_en_cnt = $urandom_range(NUM_WPORTS, 0);
            end

            if (free_scnt < wr_en_cnt) begin
                rd_en_cnt = $urandom_range(`MIN(NUM_RPORTS, used_scnt + wr_en_cnt), wr_en_cnt - free_scnt);
            end else begin
                rd_en_cnt = $urandom_range(`MIN(NUM_RPORTS, used_scnt + wr_en_cnt), 0);
            end
            @(negedge clock);
            wr_en_cnt = 0;
            rd_en_cnt = 0;
        end



        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
