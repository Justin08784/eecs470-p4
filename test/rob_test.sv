// FIFO module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh
`include "sys_defs.svh"
`include "test/rob_sva.svh"

module rob_test();
    localparam ROB_SZ = `ROB_SZ;  // num elements
    localparam NUM_RPORTS = 2;
    localparam NUM_DPORTS = 2;
    localparam NUM_CPORTS = 2;
    localparam N          = `N;

    logic                       clock, reset;
    // retire (read)
    rob2retire r_out;

    // complete (write)
    complete2rob c_in;

    // dispatch (write)
    rob2dispatch d_out;

    dispatch2rob d_in;

    ROB_ENTRY   [ROB_SZ-1:0]    state_dbg;

    task set_complete(
        input int i,
        input int rob_idx 
    );
        c_in.c_en[i]        = 1;
        c_in.c_rob_idxs[i]  = rob_idx;
    endtask

    task clr_all();
        d_in = '0;
        c_in = '0;
    endtask

    // Variable to count values written to FIFO
    int cnt;

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end
    // Generate nonzero random numbers for our write data on each cycle
    // (we shall treat a 0 as non-enabled; this allows us to print 0s in the $monitor
    // to indicate non-enabled)

    always @(negedge clock) begin
        foreach (d_in.tag[i]) begin
            d_in.tag[i]     = $urandom_range(`PHYS_REG_SZ_R10K-1, 1);
            d_in.t_old[i]   = $urandom_range(`PHYS_REG_SZ_R10K-1, 1);
        end
    end

    logic DEBUG = 1;
    always @(posedge clock) begin
        if (DEBUG) begin
            $display("  %3d | d_in: [(%d, %d, %d), (%d, %d, %d)]   wr_en_cnt: %d  rd_en_cnt: %d  |  d_out: [(%d, %d, %d), (%d, %d, %d)]",
                $time,
                d_in.tag[0],
                d_in.t_old[0],
                d_in.dst[0],
                d_in.tag[1],
                d_in.t_old[1],
                d_in.dst[1],
                // d_in.d_en_cnt > 0 ? d_in.tag[0] : 0,
                // d_in.d_en_cnt > 0 ? d_in.t_old[0] : 0,
                // d_in.d_en_cnt > 1 ? d_in.tag[1] : 0,
                // d_in.d_en_cnt > 1 ? d_in.t_old[1] : 0,
                d_in.d_en_cnt,
                r_out.r_en_cnt,
                r_out.tag[0], 
                r_out.t_old[0], 
                r_out.dst[0], 
                r_out.tag[1], 
                r_out.t_old[1],
                r_out.dst[1]);
        end
    end
    
    // FIFO instance
    rob #(
        .ROB_SZ(ROB_SZ),
        .N(N)
    ) dut (
        `ifdef DEBUG
        .state_dbg(state_dbg),
        `endif

        .clock  (clock),
        .reset  (reset),
        .r_out  (r_out),
        .c_in   (c_in),
        .d_out  (d_out),
        .d_in   (d_in)
    );

    rob_sva #(
        .ROB_SZ(ROB_SZ),
        .N(N)
    ) sva (
        `ifdef DEBUG
        .state_dbg(state_dbg),
        `endif

        .clock  (clock),
        .reset  (reset),
        .r_out  (r_out),
        .c_in   (c_in),
        .d_out  (d_out),
        .d_in   (d_in)
    );

    initial begin
        $display("\nStart Testbench");
        clock = 0;
        reset = 1;

        d_in = '0;
        c_in = '0;

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

        // Test 1:
        $display("\nTest 1: 1 inst lifecycle");
        // dispatch 1
        d_in.d_en_cnt = 1;
        @(negedge clock);
        clr_all();

        // complete it
        set_complete(0, 0);
        @(negedge clock);
        clr_all();

        // wait for it to retire
        @(negedge clock);

        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
