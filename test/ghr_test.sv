`include "sys_defs.svh"
// `include "test/ghr_sva.svh"

// enable to synthesize GHR (via `make ghr.syn.out`)
// `define SYNTH_GHR

`ifndef SYNTH_GHR
module ghr_test #(
    parameter DEPTH     = 64, // must be geq than 2*GHR_LEN and a power of 2
    parameter NUM_FU_BRU= 1,
    parameter GHR_LEN   = 8,
    parameter N         = 3,
    // try these too
    // parameter DEPTH     = 512,
    // parameter NUM_FU_BRU= 1,
    // parameter GHR_LEN   = 64,
    // parameter N         = 12,
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
    `CNT_TYPE(N)    f_en_cnt, f_rdy_scnt;
    logic [N-1:0]   f_pred;
    logic [N-1:0][GHR_LEN-1:0] f_ghr;
    PTR   [N-1:0]   f_base;
    
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
        .f_base,
        .f_ghr
    );


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

    logic DEBUG = 1;
    always @(posedge clock) begin
        if (DEBUG) begin
            $display("  %3d | fetch: {en_cnt: %1d, pred: [%b, %b]}, ex_in: {en: %b, idx: %2d}, flush: {%b, base: %2d, take: %b}",
                $time,
                f_en_cnt,
                f_pred[0],
                f_pred[1],
                ex_en,
                ex_idx,
                flush,
                flush_base,
                flush_take
            );

            // foreach(sva.nres[i])
            //     $display("  nres[%2d]: %2d", i, sva.nres[i]);

            $display("got: ghr: [%b, %b], hist: %b, rslv: %b, base: %2d (f_rdy_scnt: %2d)",
                f_ghr[0],
                f_ghr[1],
                hist,
                rslv,
                base,
                f_rdy_scnt
            );

            $display("exp: ghr: [%b, %b], hist: %b, rslv: %b, base: %2d",
                sva.sva_comb.f_ghr[0],
                sva.sva_comb.f_ghr[1],
                sva.s.hist,
                sva.s.rslv,
                sva.s.base
            );

            // $display("flush: %b, flush_base: %d, flush_take: %b", flush, flush_base, flush_take);
            // $display("hist: %b, ghr: %b", dut.hist, f_ghr[0]);
            // $display("rslv: %b", dut.rslv);
            // $display("b1ht: %b (idx: %2d) rdy: %b, okay: %b", dut.base_oh, dut.base, dut.rdy, dut.okay);
        end
    end



    int nres [$];
    localparam pred_rate = 70; // in percent
    localparam take_rate = 40; // in percent

// -----------------------------------------------------------------------------
//  RANDOMISED STRESS TEST – REPLACES THE OLD "for (int i = 0; i < 100; ++i) "
// -----------------------------------------------------------------------------
typedef struct packed {
   PTR   idx;          // where it lives in the ring
   logic pred_take;    // what we predicted at fetch time
} pend_t;

pend_t  pend[$];       // queue : pend[0] is the OLDEST (closest to commit)
int     cycles = 0;

localparam FETCH_RATE   = 75;   // % chance we will fetch at all
localparam RESOLVE_RATE = 20;   // % chance we will try to resolve something
localparam MISP_RATE    = 10;   // % chance a resolve is a mis-predict

task automatic push_new_fetches();
    int eff_cnt1, eff_cnt2;
    logic [N-1:0] raw_take;

    f_en_cnt = 0;
    f_pred   = '0;
    if (flush)
        return;

    if ($urandom_range(99, 0) >= FETCH_RATE) begin
        // nothing fetched this cycle
        return;
    end

    // decide if that slot is predicted taken (biased by TAKE_RATE)
    for (int n = 0; n < N; ++n)
        raw_take[n] = $urandom_range(99, 0) < take_rate;

    // how many can we legally fetch?
    eff_cnt1 = $urandom_range(f_rdy_scnt, 0);

    eff_cnt2 = 0;
    for (int n = 0; n < N; ++n) begin
        if (raw_take[n]) begin
            eff_cnt2    = n+1;
            f_pred[n]   = 1'b1;
            break;
        end
    end
    f_en_cnt = `MIN(eff_cnt1, eff_cnt2);

    for (int i = 0; i < f_en_cnt; ++i) begin
        pend_t b;

        // remember the branch in scoreboard
        b.idx        = f_base[i];   // <-- comes straight from DUT
        b.pred_take  = f_pred[i];
        pend.push_back(b);          // youngest at the BACK
    end
endtask


task automatic resolve_or_flush();
    int pick;
    pend_t br;
    logic actual_take;
    logic is_mispredict;
    ex_en = '0;
    ex_idx = '0;
    flush = '0;
    flush_base = '0;
    flush_take = '0;

    if (pend.size() == 0)
        return;
    if ($urandom_range(99,0) >= RESOLVE_RATE)
        return;

    // choose a random in-flight branch to resolve
    pick    = $urandom_range(pend.size()-1,0);
    br      = pend[pick];

    is_mispredict = $urandom_range(99,0) < MISP_RATE;
    actual_take   = is_mispredict ? !br.pred_take : br.pred_take;

    if (is_mispredict) begin
        int i;
        //-----------------------------------------------------------------
        // drive a FLUSH                                                     
        //-----------------------------------------------------------------
        flush       = 1;
        flush_base  = br.idx;
        flush_take  = actual_take;

        // delete br *and every younger* entry
        while(`TRUE) begin
            if (pend[$].idx == br.idx) begin
                pend.pop_back(); // the mis-predicted one
                break;
            end
            
            pend.pop_back();    // everything younger
            --i;
        end
    end else begin
        //-----------------------------------------------------------------
        // drive a CORRECT RESOLUTION                                       
        //-----------------------------------------------------------------
        ex_en[0]    = 1;
        ex_idx[0]   = br.idx;
        pend.delete(pick);
end

endtask
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


        DEBUG = 1;
        @(negedge clock);
        reset = 0;
        @(negedge clock);

        // // ---------- Test 1 ---------- //
        // $display("\nTest 1");
        // f_pred[0] = 1'b1;
        // f_en_cnt = 1;

        // while (f_rdy_scnt > 0)
        //     @(negedge clock);
        // f_en_cnt = 0;
        // @(negedge clock);

        // $display("\nTest 2");
        // ex_en   = 1;
        // ex_idx  = 2;
        // @(negedge clock);
        // ex_en       = 0;
        // @(negedge clock);

        // $display("\nTest 3");
        // flush       = 1;
        // flush_base  = 4;
        // flush_take  = 0;
        // // $display("ex_en: %b, ex_idx: %d", ex_en, ex_idx);
        // @(negedge clock);
        // flush = 0;
        // @(negedge clock);
        // @(negedge clock);


        reset = 1;
        @(negedge clock);
        reset = 0;
        @(negedge clock);
        $display("\nTest 4: Randomized stress testing");
        DEBUG = 1; // disable debugs

        // for (int i = 0; i < 100; ++i) begin
        //     int f_en_cnt1, f_en_cnt2;
        //     logic [N-1:0] raw_take;

        //     for (int n = 0; n < N; ++n)
        //         raw_take[n] = $urandom_range(100, 0) < take_rate;

        //     f_pred = '0;
        //     f_en_cnt1 = $urandom_range(f_rdy_scnt, 0);
        //     f_en_cnt2 = 0;
        //     for (int n = 0; n < N; ++n) begin
        //         if (raw_take[n]) begin
        //             f_en_cnt2   = n+1;
        //             f_pred[n]   = 1;
        //             break;
        //         end
        //     end
        //     f_en_cnt = `MIN(f_en_cnt1, f_en_cnt2);

        //     @(negedge clock);
        // end

        //... the directed tests you already had ...

        // reset  = 1; @(negedge clock); reset = 0; @(negedge clock);
        // DEBUG  = 0;    // turn off verbose wave print

        repeat (1000) begin        // run for 10 000 cycles
            // foreach(pend[i])
            //     $display("  pend[%2d]: pt: %b, idx: %2d", i, pend[i].pred_take, pend[i].idx);
            resolve_or_flush();
            push_new_fetches();

            @(negedge clock);         // advance time
            cycles++;
        end

        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
`endif
