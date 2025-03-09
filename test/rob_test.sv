// FIFO module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh
`include "sys_defs.svh"
`include "test/rob_sva.svh"

module rob_test();
    localparam DEPTH = `ROB_SZ;
    localparam WIDTH = $bits(PHYS_REG_IDX);
    localparam NUM_RPORTS = 2;
    localparam NUM_WPORTS = 2;
    localparam MAX_SCNT   = 2;
    localparam N          = `N;

    logic                       clock, reset;
    // retire (read)
    struct packed {
        logic [$clog2(N):0]     r_en_cnt;
        PHYS_REG_IDX [N-1:0]    tag;
        PHYS_REG_IDX [N-1:0]    t_old;
    } r_out;

    // complete (write)
    struct packed {
        logic [N-1:0]           c_en;
        ROB_IDX [N-1:0]         c_rob_idxs;
    } c_in;

    // dispatch (write)
    struct packed {
        logic [$clog2(N):0]     rob_rdy_scnt;
    } d_out;

    struct packed {
        logic [$clog2(N):0]     d_en_cnt;
        logic [N-1:0][$clog2(`PHYS_REG_SZ_R10K)-1:0] tag;
        logic [N-1:0][$clog2(`PHYS_REG_SZ_R10K)-1:0] t_old;
    } d_in;

    // Variable to count values written to FIFO
    int cnt;

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end
    // Generate nonzero random numbers for our write data on each cycle
    // (we shall treat a 0 as non-enabled; this allows us to print 0s in the $monitor
    // to indicate non-enabled)

    logic [N-1:0][$clog2(`PHYS_REG_SZ_R10K)-1:0] tags;
    logic [N-1:0][$clog2(`PHYS_REG_SZ_R10K)-1:0] t_olds;
    generate
    for (genvar i = 0; i < N; i++) begin : gen_vecs // ms1 test: make loop count RS_SZ-1 instead of RS_SZ (caught)
        assign tags[i] = d_in.tag[i]; // ms1 test: make busy_vec sequential instead of combinational (caught)
        assign t_olds[i] = d_in.t_old[i];
    end
    endgenerate
    always @(negedge clock) begin
        std::randomize(tags) with {
            foreach(tags[i])
                tags[i] != 0;
        };
        std::randomize(t_olds) with {
            foreach(t_olds[i])
                t_olds[i] != 0;
        };
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
    rob #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .N(N)
    ) dut (
        .r_out  (r_out),
        .c_in   (c_in),
        .d_out  (d_out),
        .d_in   (d_in)
    );

    rob_sva #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .N(N)
    ) sva (
        .r_out  (r_out),
        .c_in   (c_in),
        .d_out  (d_out),
        .d_in   (d_in)
    );

    initial begin
        $display("\nStart Testbench");
        clock = 0;
        reset = 1;
        // wr_en_cnt = 0;
        // rd_en_cnt = 0;

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

        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
