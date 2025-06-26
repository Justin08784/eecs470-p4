`include "sys_defs.svh"
// `include "test/ghr_sva.svh"

// enable to synthesize GHR (via `make ghr.syn.out`)
// `define SYNTH_GHR

`ifndef SYNTH_GHR
module ghr_test;
    // params and types
    localparam DEPTH    = 128;
    localparam GHR_LEN  = 40;

    localparam WPORTS   = 2;
    typedef logic [DEPTH-1:0] VEC;
    typedef logic [$clog2(DEPTH)-1:0] PTR;

    // declare signals
    logic   clock;
    logic   reset;

    logic   flush;
    logic   flush_take;
    PTR     flush_idx;

    `CNT_TYPE(WPORTS)   wen_cnt;
    logic [WPORTS-1:0]  wpred;
    PTR base_n1;
    PTR ridx;
    logic [GHR_LEN-1:0] ghist;
    
    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    ghr #(
        .DEPTH      (DEPTH),
        .GHR_LEN    (GHR_LEN),

        .WPORTS     (WPORTS)
    ) dut (
        .clock,
        .reset,

        .flush,
        .flush_take,
        .flush_idx,

        .wen_cnt,
        .wpred,
        .base_n1,

        .ridx,
        .ghist
    );

    VEC hist;
    PTR base;
    assign hist = dut.hist;
    assign base = dut.base;

    ghr_sva #(
        .DEPTH      (DEPTH),
        .GHR_LEN    (GHR_LEN),

        .WPORTS     (WPORTS)
    ) sva (
        .hist,
        .base,

        .clock,
        .reset,

        .flush,
        .flush_take,
        .flush_idx,

        .wen_cnt,
        .wpred,
        .base_n1,

        .ridx,
        .ghist
    );

    logic DEBUG = 1;
    always @(posedge clock) begin
        if (DEBUG) begin
            $display("  %3d | fetch: {en_cnt: %1d, pred: [%b, %b]}, flush: {%b, idx: %2d, take: %b}",
                $time,
                wen_cnt,
                wpred[0],
                wpred[1],
                flush,
                flush_idx,
                flush_take
            );

            $display("got: hist: %b, base: %2d, ghist: %b",
                hist,
                base,
                ghist
            );

            $display("exp: hist: %b, base: %2d, ghist: %b",
                sva.s.hist,
                sva.s.base,
                sva.sva_comb.ghist
            );
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
    int eff_cnt;
    logic [N-1:0] raw_take;

    wen_cnt = 0;
    wpred   = '0;
    if (flush)
        return;

    if ($urandom_range(99, 0) >= FETCH_RATE) begin
        // nothing fetched this cycle
        return;
    end

    // decide if that slot is predicted taken (biased by TAKE_RATE)
    for (int n = 0; n < N; ++n)
        raw_take[n] = $urandom_range(99, 0) < take_rate;

    eff_cnt = 0;
    for (int n = 0; n < N; ++n) begin
        if (raw_take[n]) begin
            eff_cnt = n+1;
            wpred[n]= 1'b1;
            break;
        end
    end
    wen_cnt = eff_cnt;

    for (int i = 0; i < wen_cnt; ++i) begin
        pend_t b;

        // remember the branch in scoreboard
        b.idx        = base_n1 - PTR'(i);   // <-- comes straight from DUT
        b.pred_take  = wpred[i];
        pend.push_back(b);          // youngest at the BACK
    end
endtask


task automatic resolve_or_flush();
    int pick;
    pend_t br;
    logic actual_take;
    logic is_mispredict;
    flush       = '0;
    flush_idx   = '0;
    flush_take  = '0;

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
        flush   = 1;
        flush_idx = br.idx;
        flush_take= actual_take;

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
        pend.delete(pick);
    end

endtask
    initial begin
        $display("\nStart Testbench");
        clock   = 0;
        reset   = 1;

        flush   = 0;
        flush_take= '0;
        flush_idx = '0;

        wen_cnt = 0;
        wpred   = '0;

        ridx    = '0; // FIXME


        DEBUG = 1;
        @(negedge clock);
        reset = 0;
        @(negedge clock);

        // // ---------- Test 1 ---------- //
        // $display("\nTest 1");
        // wpred[0] = 1'b1;
        // wen_cnt = 1;

        // while (rdy_scnt > 0)
        //     @(negedge clock);
        // wen_cnt = 0;
        // @(negedge clock);

        // $display("\nTest 2");
        // cen   = 1;
        // cidx  = 2;
        // @(negedge clock);
        // cen       = 0;
        // @(negedge clock);

        // $display("\nTest 3");
        // flush       = 1;
        // flush_base  = 4;
        // flush_take  = 0;
        // // $display("cen: %b, cidx: %d", cen, cidx);
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

        repeat (1000) begin
            resolve_or_flush();
            push_new_fetches();

            @(negedge clock);
            cycles++;
        end

        $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end


endmodule
`endif
