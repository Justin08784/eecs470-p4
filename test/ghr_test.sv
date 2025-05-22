`include "sys_defs.svh"
`include "test/ghr_sva.svh"

module ghr_test();
    localparam DEPTH = 32;
    typedef logic [$clog2(DEPTH)-1:0] PTR;

    logic   clock;
    logic   reset;
    logic   flush;
    PTR     flush_base;
    logic   flush_take;

    // ex (correct resolutions)
    logic [`NUM_FU_BRU-1:0] ex_en;
    PTR   [`NUM_FU_BRU-1:0] ex_idx;

    // fetch
    logic [$clog2(`N):0] f_en_cnt;
    logic [`N-1:0]       f_pred;
    logic [$clog2(`N):0] f_rdy_scnt;
    logic [`N-1:0][GHR_LEN-1:0] f_ghr;
    
    // Variable to count values written to FIFO
    int cnt;

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    // Generate nonzero random numbers for our write data on each cycle
    // (we shall treat a 0 as non-enabled; this allows us to print 0s in the $monitor
    // to indicate non-enabled)
    always @(negedge clock) begin
        // std::randomize(wr_data) with {
        //     foreach(wr_data[i])
        //         wr_data[i] != 0;
        // };
    end

    logic DEBUG = 1;
    always @(posedge clock) begin
        if (DEBUG) begin
            $write("  %3d | ", $time);
            $display("  %3d | ex_in: {en: %b, idx: %2d}, fetch: {en_cnt: %1d, rdy_cnt: %1d, pred: [%b, %b], ghr: %b}",
                $time,
                ex_en,
                ex_idx,
                f_en_cnt,
                f_rdy_scnt,
                f_pred[0],
                f_pred[1],
                f_ghr[0]
            );
        end
    end
    

    ghr #(
        .DEPTH(DEPTH)
    ) dut (
        .clock,
        .reset,
        .flush      ('0),
        .flush_base ('0),
        .flush_take ('0),

        .ex_en,
        .ex_idx,

        .f_en_cnt,
        .f_pred,
        .f_rdy_scnt,
        .f_ghr
    );

    // ghr_sva #(
    //     .DEPTH(DEPTH),
    //     .WIDTH(WIDTH),
    //     .NUM_RPORTS(NUM_RPORTS),
    //     .NUM_WPORTS(NUM_WPORTS),
    //     .ENABLE_INTR_FWD(`TRUE)
    // ) sva (
    //     .clock      (clock),
    //     .reset      (reset),
    //     .wr_en_cnt  (wr_en_cnt),
    //     .wr_data    (wr_data),
    //     .rd_en_cnt  (rd_en_cnt),
    //     .rd_data    (rd_data),
    //     .free_scnt  (free_scnt),
    //     .used_scnt  (used_scnt)
    // );

    initial begin
        $display("\nStart Testbench");
        clock = 0;
        reset = 1;
        flush = 0;

        flush_base  = '0;
        flush_take  = '0;
        ex_en       = '0;
        ex_idx      = '0;

        f_en_cnt    = 0;
        f_pred      = 0;


        @(negedge clock);
        reset = 0;
        @(negedge clock);

        // ---------- Test 1 ---------- //

        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
