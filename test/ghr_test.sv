`include "sys_defs.svh"
`include "test/ghr_sva.svh"

module ghr_test #(
    parameter DEPTH     = 8, // must be geq than 2*GHR_LEN and a power of 2
    parameter NUM_FU_BRU= 1,
    parameter GHR_LEN   = 4,
    parameter N         = 2,
    type VEC = logic [DEPTH-1:0],
    type PTR = logic [$clog2(DEPTH)-1:0]
) ();
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

    ghr #(
        .DEPTH      (DEPTH),
        .NUM_FU_BRU (NUM_FU_BRU),
        .GHR_LEN    (GHR_LEN),
        .N          (N)
    ) dut (
        .clock,
        .reset,
        .flush,
        .flush_base,
        .flush_take,

        .ex_en,
        .ex_idx,

        .f_en_cnt,
        .f_pred,
        .f_rdy_scnt,
        .f_ghr
    );

    logic DEBUG = 1;
    always @(posedge clock) begin
        if (DEBUG) begin
            $write("  %3d | ", $time);
            $display("  %3d | ex_in: {en: %b, idx: %2d}, fetch: {en_cnt: %1d, rdy_scnt: %1d, pred: [%b, %b], ghr: [%b, %b]}",
                $time,
                ex_en,
                ex_idx,
                f_en_cnt,
                f_rdy_scnt,
                f_pred[0],
                f_pred[1],
                f_ghr[0],
                f_ghr[1]
            );
            $display("flush: %b, flush_base: %d, flush_take: %b", flush, flush_base, flush_take);
            $display("hist: %b, ghr: %b", dut.hist, f_ghr[0]);
            $display("rslv: %b", dut.rslv);
            $display("b1ht: %b (idx: %2d) rdy: %b, okay: %b", dut.base_oh, dut.base, dut.rdy, dut.okay);
        end
    end


    VEC     rslv;
    VEC     hist;
    PTR     base;
    VEC     base_oh;
    VEC     okay;
    always_comb begin
        rslv    = dut.rslv;
        hist    = dut.hist;
        base    = dut.base;
        base_oh = dut.base_oh;
        okay    = dut.okay;
    end

    ghr_sva #(
        .DEPTH      (DEPTH),
        .NUM_FU_BRU (NUM_FU_BRU),
        .GHR_LEN    (GHR_LEN),
        .N          (N)
    ) sva (
        .rslv,
        .hist,
        .base,
        .base_oh,
        .okay,

        .clock,
        .reset,

        .flush,
        .flush_base,
        .flush_take,

        .ex_en,
        .ex_idx,

        .f_en_cnt,
        .f_pred,
        .f_rdy_scnt,
        .f_ghr
    );


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
        $display("\nTest 1");
        f_pred[0] = 1'b1;
        f_en_cnt = 1;

        while (f_rdy_scnt > 0)
            @(negedge clock);
        f_en_cnt = 0;
        @(negedge clock);

        $display("\nTest 2");
        ex_en   = 1;
        ex_idx  = 1;
        @(negedge clock);
        @(negedge clock);

        $display("\nTest 3");
        flush       = 1;
        flush_base  = 3;
        flush_take  = 0;
        ex_en       = 0;
        ex_idx      = 0;
        // $display("ex_en: %b, ex_idx: %d", ex_en, ex_idx);
        @(negedge clock);
        flush = 0;
        @(negedge clock);
        @(negedge clock);




        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
