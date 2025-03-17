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
    IF_ID_PACKET [`N-1:0] tmp;
    always @(negedge clock) begin
        std::randomize(tmp);
        f_in.f_dat = tmp;
    end

    logic DEBUG = 1;
    always @(posedge clock) begin
        if (DEBUG) begin
            $display("  %3d | d_in: PC[%x, %x] inst[%x, %x] wr_en_cnt: %d  rd_en_cnt: %d  |  d_out: PC[%x, %x] inst[%x,%x]",
                $time,
                f_in.f_en_cnt > 0 ? f_in.f_dat[0].PC : 0,
                f_in.f_en_cnt > 1 ? f_in.f_dat[1].PC : 0,
                f_in.f_en_cnt > 0 ? f_in.f_dat[0].inst : 0,
                f_in.f_en_cnt > 1 ? f_in.f_dat[1].inst : 0,
                f_in.f_en_cnt,
                d_in.dispatch_en_cnt,
                d_out.d_dat[0].PC, 
                d_out.d_dat[1].PC,
                d_out.d_dat[0].inst, 
                d_out.d_dat[1].inst
            );
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


        // ---------- Test 15 ---------- //
        $display("\nTest 15: Forwarding");

        $display("1 read: from state");
        f_in.f_en_cnt = 1;
        @(negedge clock);
        f_in.f_en_cnt = 0;

        d_in.dispatch_en_cnt = 1;
        @(negedge clock);
        d_in.dispatch_en_cnt = 0;

        // $display("1 read: fwded");
        // f_in.f_en_cnt = 1;
        // d_in.dispatch_en_cnt = 1;
        // @(negedge clock);
        // f_in.f_en_cnt = 0;
        // d_in.dispatch_en_cnt = 0;

        $display("2 reads: both from state");
        f_in.f_en_cnt = 2;
        @(negedge clock);
        f_in.f_en_cnt = 0;

        d_in.dispatch_en_cnt = 2;
        @(negedge clock);
        d_in.dispatch_en_cnt = 0;

        // $display("2 reads: 1 from state, 1 fwded");
        // f_in.f_en_cnt = 1;
        // @(negedge clock);

        // d_in.dispatch_en_cnt = 2;
        // @(negedge clock);
        // f_in.f_en_cnt = 0;
        // d_in.dispatch_en_cnt = 0;

        // $display("2 reads: both fwded");
        // f_in.f_en_cnt = 2;
        // d_in.dispatch_en_cnt = 2;
        // @(negedge clock);
        // f_in.f_en_cnt = 0;
        // d_in.dispatch_en_cnt = 0;




        // ---------- Test N ---------- //
        $display("\nTest N: Randomized stress testing");
        DEBUG = 0; // disable debugs
        for (int i = 0; i < 10000; ++i) begin
            f_in.f_en_cnt = $urandom_range(`MIN(NUM_WPORTS, f_out.d_rdy_cnt), 0);
            d_in.dispatch_en_cnt = $urandom_range(`MIN(NUM_WPORTS, d_out.d_vld_scnt), 0);

            @(negedge clock);
            f_in.f_en_cnt = 0;
            d_in.dispatch_en_cnt = 0;
        end



        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
