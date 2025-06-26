`include "sys_defs.svh"

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
    input   logic [WPORTS-1:0]  wpred,
    output  PTR     base_n1,

    // retire
    input   PTR     ridx,

    // ghist slice (flush and retire use the same rotator; flush takes precedence)
    // FIXME: must stall retire during flush
    output  logic [GHR_LEN-1:0] ghist
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
    assign wval[0]  = flush ? flush_take: wpred[0];
    for (genvar i = 1; i < WPORTS; ++i) begin
        assign wen [i] = i < wen_cnt;
        assign widx[i] = base_n[i+1];
        assign wval[i] = wpred[i];
    end
    endgenerate

    // ghist slice: mux flush and retire read
    assign ghist = {hist, hist} >> (flush ? flush_idx : ridx);
    
    always_ff @(posedge clock) begin
        if (reset) begin
            hist    <= '0;
                // hist <= 'hACE1; // heuristic seed to avoid cold start
            base    <= '0;

        end else begin
            for (int i = 0; i < WPORTS; ++i) begin
                if (!wen[i])
                    continue;
                hist[widx[i]] <= wval[i];
            end
            base    <= flush ? flush_idx : base_n[wen_cnt];

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
//                 en_pred[i] = wpred[i];
//             assert(!(|en_pred) || $onehot(en_pred)) else
//                 $fatal("ghr: en_pred (%b) is not one-hot", en_pred);
//         end

//     end
// `endif


// `ifdef DEBUG
//     task print_ghr;
//         $display(">> ghr >>");
//         $display("  %3d | fetch: {en_cnt: %1d, pred: [%b, %b]}, ex_in: {en: %b, idx: %2d}, flush: {%b, base: %2d, take: %b}",
//             $time,
//             wen_cnt,
//             wpred[0],
//             wpred[1],
//             cen,
//             cidx,
//             flush,
//             cidx[0],
//             ctake[0],
//         );

//         // foreach(sva.nres[i])
//         //     $display("  nres[%2d]: %2d", i, sva.nres[i]);

//         $display("got: ghr: %b, hist: %b, rslv: %b, base: %2d (f_rdy_scnt: %2d)",
//             rghr,
//             hist,
//             rslv,
//             base,
//             rdy_scnt
//         );
//         $display("<< ghr <<");
//     endtask
// `endif

endmodule