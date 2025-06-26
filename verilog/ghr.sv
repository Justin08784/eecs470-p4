`include "sys_defs.svh"


module fhr #(
    parameter GHR_LEN   = 80,
    parameter FH_LEN    = 10,

    parameter WPORTS    = NUM_BR_SLOTS
) (
    input   clock,
    input   reset,

    // misprediction flush
    input   flush,

    input   logic [GHR_LEN-1:0] qry_ghist,
    output  logic [FH_LEN-1:0]  rd_fh,

    // fetch
    input   `CNT_TYPE(WPORTS)   wen_cnt,
    input   logic [WPORTS-1:0]  wshf_in,
    input   logic [WPORTS-1:0]  wshf_out,
    output  logic [FH_LEN-1:0]  fh
);
    logic [FH_LEN-1:0] fh_flush;
    logic [WPORTS:0][FH_LEN-1:0] fh_n;
    localparam last = (GHR_LEN-1) % FH_LEN;

    initial begin
        assert (GHR_LEN >= FH_LEN) else $fatal;
        assert (FH_LEN <= $bits(WADDR)) else $fatal;
    end

    function automatic logic [FH_LEN-1:0] compute_fh (
        input logic [GHR_LEN-1:0] ghist
    );
        localparam H = (GHR_LEN + FH_LEN - 1) / FH_LEN; // round up integer division
        logic [FH_LEN-1:0] rv;

        rv = ghist[FH_LEN-1:0];
        for (int i = 0; i < FH_LEN; ++i) begin
            for (int h = 1; h < H; ++h) begin
                int unsigned idx;
                idx = FH_LEN*h + i;
                if (idx < GHR_LEN)
                    rv[i] ^= ghist[idx];
                else
                    continue;
            end
        end

        return rv;
    endfunction

    localparam logic [FH_LEN-1:0] fh_rst = compute_fh('0);
    assign fh_flush = compute_fh(qry_ghist);
    assign rd_fh = fh_flush;

    function automatic logic [FH_LEN-1:0] update_fh (
        input logic [FH_LEN-1:0] pre,
        input logic in,
        input logic out
    );
        logic [FH_LEN-1:0] rv;
        logic [2*FH_LEN-1:0] cat_shf;
        rv = pre;
        rv[last]^= out;
        cat_shf = {rv, rv} << 1;
        rv = cat_shf[FH_LEN +: FH_LEN];
        rv[0]   ^= in;

        return rv;
    endfunction

    generate
    assign fh_n[0] = fh;

    for (genvar i = 1; i <= WPORTS; ++i)
        assign fh_n[i] = update_fh(fh_n[i-1], wshf_in[i-1], wshf_out[i-1]);
    endgenerate

    always_ff @(posedge clock) begin
        if (reset)
            fh <= fh_rst;
        else
            fh <= flush ? fh_flush : fh_n[wen_cnt];
    end

endmodule

/*
TODO: The ghr must be sized large enough so that base does not write into the
non-recoverable zone (NRZ). This invariant is what allows us to to eliminate the
expensive "rslv" maintenance logic. Need assertions to check this during runtime.
*/
module ghr #(
    // parameter DEPTH     = 512, // must be geq than 2*GHR_LEN and a power of 2
    // parameter GHR_LEN   = 256,
    // parameter DEPTH     = 256,
    // parameter GHR_LEN   = 8 * $bits(WADDR),

    // parameter DEPTH     = 128,
    // parameter GHR_LEN   = 40,
    parameter DEPTH     = 128,
    parameter GHR_LEN   = 80,

    parameter WPORTS    = NUM_BR_SLOTS, // number of predictions that can be shifted in
    type VEC = logic [DEPTH-1:0],
    type PTR = logic [$clog2(DEPTH)-1:0]
) (
    input   clock,
    input   reset,

    // misprediction flush
    input           flush,
    input   logic   flush_take,
    input   PTR     flush_idx, // base BEFORE shifting in current branch's pred

    // fetch
    input   `CNT_TYPE(WPORTS)   wen_cnt,
    input   logic [WPORTS-1:0]  wshf_in,
    output  logic [WPORTS-1:0]  wshf_out,
    output  PTR     base_n1,

    // retire
    input   PTR     ridx,

    // ghist slice (flush and retire use the same rotator; flush takes precedence)
    // FIXME: must stall retire during flush
    output  logic [GHR_LEN-1:0] rd_ghist
);
    initial begin
        assert(N < DEPTH) else // FIXME
            $fatal("GHR: N (%0d) must be smaller than DEPTH (%0d)", N, DEPTH);

        assert ((DEPTH != 0) && ((DEPTH & (DEPTH - 1)) == 0))
            else $fatal("GHR DEPTH must be a power of 2");

        // assert (DEPTH >= 2*GHR_LEN)
        //     else $fatal("GHR DEPTH must be >= 2*GHR_LEN");
    end

    VEC hist; // {0=ntake, 1=take}
    logic [GHR_LEN-1:0] ghist;
    PTR base; // to youngest entry in the GHR window; (base-1) % DEPTH is the write head

    PTR [WPORTS:0]      base_n;
    generate
    assign base_n[0] = base;
    for (genvar k = 1; k < WPORTS+1; ++k)
        assign base_n[k] = base - `UCAST_FIT(k);
    assign base_n1 = base_n[1];
    endgenerate

    // write ports: mux flush and fetch writes
    logic   [WPORTS-1:0] wen, wval;
    PTR     [WPORTS-1:0] widx;
    generate
    assign wen[0]   = flush | (wen_cnt != 0);
    assign widx[0]  = flush ? flush_idx : base_n[1];
    assign wval[0]  = flush ? flush_take: wshf_in[0];
    for (genvar i = 1; i < WPORTS; ++i) begin
        assign wen [i] = i < wen_cnt;
        assign widx[i] = base_n[i+1];
        assign wval[i] = wshf_in[i];
    end
    endgenerate

    // ghist slice: mux flush and retire read
    always_comb begin
        rd_ghist = {hist, hist} >> (flush ? flush_idx : ridx);
        if (flush) begin
            rd_ghist[0] &= 0;
            // rd_ghist &= ~(1'b1);
            rd_ghist[0] |= flush_take;
        end
    end

    generate
    for (genvar i = 0; i < WPORTS; ++i)
        assign wshf_out[i] = ghist[GHR_LEN-i-1];

    logic [GHR_LEN+WPORTS-1:0] ghist_win;
    logic [WPORTS-1:0] rev_wshf_in;
    for (genvar i = 0; i < WPORTS; ++i)
        assign rev_wshf_in[i] = wshf_in[WPORTS-i-1];

    // assign ghist_win = {ghist, rev_wshf_in} << `MIN(wen_cnt, WPORTS);
    assign ghist_win = {ghist, rev_wshf_in} << wen_cnt;
    endgenerate

    always_ff @(posedge clock) begin
        if (reset) begin
            hist    <= '0;
                // hist <= 'hACE1; // heuristic seed to avoid cold start
            base    <= '0;
            ghist   <= '0;

        end else begin
            for (int i = 0; i < WPORTS; ++i) begin
                if (!wen[i])
                    continue;
                hist[widx[i]] <= wval[i];
            end
            base    <= flush
                ? flush_idx
                : base_n[wen_cnt];
            ghist   <= flush
                ? rd_ghist
                : ghist_win[WPORTS +: GHR_LEN];

        end

    end


// `ifdef FORMAL
//     always_ff @(posedge clock) begin
//         // runtime assertions
//         if (!reset) begin
//             logic [WPORTS-1:0] en_pred;
//             assert(!flush || !rslv[cidx[0]]) else
//                 $fatal("ghr: flush base %2d is already resolved", cidx[0]);
//             // assert(!flush || hist[flush_base] != flush_take) else
//             //     $fatal("ghr: flush take %b matches existing history", flush_take);
//             /* Reason for disabling this asssertion:
//             We must still perform flush even if the flush_take matches the hist record
//             (Q: How can this happen? A: target mismatch).

//             If we do not, we will fail to mark-resolve the dependent branches on the
//             mispredicted path and the ghr will stall forever. (This is also why we
//             cannot move to a simple "invert" hist value iff flush.)
//             */

//             for (int i = 0; i < CPORTS; ++i) begin
//                 assert(!cen[i] || !rslv[cidx[i]]) else
//                     $fatal("ghr: ex_idx %2d is already resolved", cidx[i]);
//             end
//             // assert(!(|f_pred) || $onehot(f_pred)) else
//             //     $fatal("ghr: f_pred (%b) is not one-hot", f_pred);

//             en_pred = '0;
//             for (int i = 0; i < wen_cnt; ++i)
//                 en_pred[i] = wshf_in[i];
//             assert(!(|en_pred) || $onehot(en_pred)) else
//                 $fatal("ghr: en_pred (%b) is not one-hot", en_pred);
//         end

//     end
// `endif


`ifdef DEBUG
    task print_ghr;
        $display(">> ghr >>");
        $display("  %3d | fetch: {en_cnt: %1d, pred: [%b, %b]}, flush: {%b, base: %2d, take: %b}",
            $time,
            wen_cnt,
            wshf_in[0],
            wshf_in[1],

            flush,
            flush_idx,
            flush_take
        );

        $display("ghist: %b. hist: %b", ghist, hist);

        // foreach(sva.nres[i])
        //     $display("  nres[%2d]: %2d", i, sva.nres[i]);

        // $display("got: ghr: %b, hist: %b, rslv: %b, base: %2d (f_rdy_scnt: %2d)",
        //     rghr,
        //     hist,
        //     rslv,
        //     base,
        //     rdy_scnt
        // );
        // $display("<< ghr <<");
    endtask
`endif

endmodule