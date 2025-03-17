`include "sys_defs.svh"
`include "test/stage_id_p4_sva.svh"

module stage_id_p4_test();
    localparam DEPTH = `ROB_SZ;
    localparam WIDTH = $bits(PHYS_REG_IDX);
    localparam NUM_RPORTS = 2;
    localparam NUM_WPORTS = 2;
    localparam MAX_SCNT   = 2;

    int id;
    logic           clock, reset;
    fetch2decode    f_in;
    decode2fetch    f_out;
    dispatch2decode d_in;
    decode2dispatch d_out;
    
    // Variable to count values written to FIFO
    int cnt;

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end
    // Generate nonzero random numbers for our write data on each cycle
    // (we shall treat a 0 as non-enabled; this allows us to print 0s in the $monitor
    // to indicate non-enabled)
    always @(negedge clock) begin
        // std::randomize(f_in);
    end

    logic DEBUG = 1;
    always @(posedge clock) begin
        if (DEBUG) begin
            // $display("  %3d | d_in: [%d, %d]   wr_en_cnt: %d  rd_en_cnt: %d  |  d_out: [%d, %d]   used_scnt: %2d  free_scnt: %2d",
            //     $time,
            //     wr_en_cnt > 0 ? wr_data[0] : 0,
            //     wr_en_cnt > 1 ? wr_data[1] : 0,
            //     wr_en_cnt,
            //     rd_en_cnt,
            //     rd_data[0], 
            //     rd_data[1], 
            //     used_scnt, 
            //     free_scnt);
        end
    end
    
    // FIFO instance
    stage_id_p4 dut (
        .clock  (clock),
        .reset  (reset),
        .f_in   (f_in),
        .f_out  (f_out),
        .d_in   (d_in),
        .d_out  (d_out)
    );

    stage_id_p4_sva sva (
        .clock  (clock),
        .reset  (reset),
        .f_in   (f_in),
        .f_out  (f_out),
        .d_in   (d_in),
        .d_out  (d_out)
    );

    initial begin
        $display("\nStart Testbench");
        id = 0;
        clock = 0;
        reset = 1;
        f_in  = '0;
        d_in  = '0;

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



        // ---------- Test 16 ---------- //
        // $display("\nTest 16: Randomized stress testing");
        // DEBUG = 0; // disable debugs
        // for (int i = 0; i < 10000; ++i) begin
        //     if (free_scnt < NUM_WPORTS) begin
        //         wr_en_cnt = $urandom_range(`MIN(NUM_WPORTS, free_scnt + NUM_RPORTS), 0);
        //     end else begin
        //         wr_en_cnt = $urandom_range(NUM_WPORTS, 0);
        //     end

        //     if (free_scnt < wr_en_cnt) begin
        //         rd_en_cnt = $urandom_range(`MIN(NUM_RPORTS, used_scnt + wr_en_cnt), wr_en_cnt - free_scnt);
        //     end else begin
        //         rd_en_cnt = $urandom_range(`MIN(NUM_RPORTS, used_scnt + wr_en_cnt), 0);
        //     end
        //     @(negedge clock);
        //     wr_en_cnt = 0;
        //     rd_en_cnt = 0;
        // end



        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
