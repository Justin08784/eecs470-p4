`include "sys_defs.svh"


module fhr #(
    parameter GHR_LEN   = 80,
    parameter FH_LEN    = 10,

    parameter WPORTS    = NUM_BR_SLOTS
) (
    input   clock,
    input   reset,

    // redirection
    input   redir,

    input   logic [GHR_LEN-1:0] qry_ghist,
    output  logic [FH_LEN-1:0]  rd_fh,

    // fetch
    input   logic [WPORTS-1:0]  wen,
    input   logic [WPORTS-1:0]  wshf_in,
    input   logic [WPORTS-1:0]  wshf_out,
    output  logic [FH_LEN-1:0]  fh
);
    logic [FH_LEN-1:0] fh_redir;
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
    assign rd_fh = compute_fh(qry_ghist);
    assign fh_redir = rd_fh;

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
        fh <= redir ? fh_redir : fh_n[$countones(wen)];

        if (reset)
            fh <= fh_rst;
    end

endmodule

module ghr #(
    // parameter DEPTH     = 512, // must be geq than 2*GHR_LEN and a power of 2
    // parameter GHR_LEN   = 384,
    parameter DEPTH     = 128,
    parameter GHR_LEN   = 80,

    parameter WPORTS    = NUM_BR_SLOTS, // number of predictions that can be shifted in
    type VEC = logic [DEPTH-1:0],
    type PTR = logic [$clog2(DEPTH)-1:0]
) (
    input   clock,
    input   reset,

    // redirection
    input   redir,  // flush | steer_s{2, 3}
    input   logic [WPORTS-1:0]  redir_wen,
    input   logic [WPORTS-1:0]  redir_take,
    input   PTR                 redir_idx,

    // fetch
    input   logic [WPORTS-1:0]  wen,
    input   logic [WPORTS-1:0]  wshf_in,
    output  logic [WPORTS-1:0]  wshf_out,
    output  PTR     base_n1, // ghr index of the next shifted-in branch

    // retire
    input   PTR     ridx,

    // ghist slice (NOTE: redirection and retire use the same rotator; redirection gets priority)
    output  logic [GHR_LEN-1:0] rd_ghist
);
    initial begin
        assert(WPORTS < DEPTH) else
            $fatal("GHR: WPORTS (%0d) must be smaller than DEPTH (%0d)", WPORTS, DEPTH);

        assert(DEPTH >= GHR_LEN) else
            $fatal("GHR: DEPTH (%0d) must be greater than or equal to GHR_LEN (%0d)", DEPTH, GHR_LEN);

        assert ((DEPTH != 0) && ((DEPTH & (DEPTH - 1)) == 0))
            else $fatal("GHR DEPTH must be a power of 2");

        assert (WPORTS == 2)
            else $fatal("ghr: impl is hardcoded to WPORTS=2, but was given WPORTS=%0d", WPORTS);
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

    // write ports: mux redir and fetch writes
    struct packed {
        logic   [WPORTS-1:0] en, val;
        PTR     [WPORTS-1:0] idx;
    } w, w_n;
    PTR [WPORTS-1:0] redir_widx;

    generate
    assign redir_widx[0] = redir_idx;
    assign redir_widx[1] = redir_idx - 1'b1;
    PTR     redir_base_n;
    assign  redir_base_n = redir_idx - redir_wen[1];

    assign w_n.en = redir ? redir_wen : wen;
    for (genvar i = 0; i < WPORTS; ++i) begin
        assign w_n.idx[i] = redir ? redir_widx[i] : base_n[i+1];
        assign w_n.val[i] = redir ? redir_take[i] : wshf_in[i];
    end
    endgenerate

    // ghist slice: mux redir and retire read
    always_comb begin
        rd_ghist = {hist, hist} >> (redir ? redir_base_n : ridx);
        if (redir & redir_wen[0]) begin
            rd_ghist[0] &= 0;

            if (redir_wen[1]) begin
                rd_ghist[1] &= 0;

                rd_ghist[1] |= redir_take[0];
                rd_ghist[0] |= redir_take[1];
            end else
                rd_ghist[0] |= redir_take[0];
        end
    end

    `CNT_TYPE(WPORTS) wen_cnt;
    assign wen_cnt = $countones(wen);

    generate
    for (genvar i = 0; i < WPORTS; ++i)
        assign wshf_out[i] = ghist[GHR_LEN-i-1];

    logic [GHR_LEN+WPORTS-1:0] ghist_win;
    logic [WPORTS-1:0] rev_wshf_in;
    for (genvar i = 0; i < WPORTS; ++i)
        assign rev_wshf_in[i] = wshf_in[WPORTS-i-1];

    assign ghist_win = {ghist, rev_wshf_in} << wen_cnt;
    endgenerate

    always_ff @(posedge clock) begin
        /* NOTE: hist latches in the wshf_in bits 1 cycle after the bits are presented
        (vs. ghist, which latches same cycle). Hence, hist lags behind ghist by 1 cycle.
        hist is written 1 cycle after ghist to move s1 uftb lookup off critical path;
        unlike wshf_in->ghist, which touches 2 fixed bit positions, wshf_in->hist
        performs two random writes into the full ghr buffer.

        Why this doesn't break correctness:
        Case 1: redir (flush or steer2/3) low
        Next cycle, all predictor stages will read ghist, which is up-to-date,
        and no one will consume hist.

        Case 2: redir high
        fhr and ghist must be reconstructed from hist, so the GHR_LEN subsegment of
        hist to which we will rollback must be up-to-date **this very cycle**.

        Consider the configuration:
        s1:fb3 -> s2:fb2 -> s3:fb1 -> ftq:fb0
        (<stage>:<occupant>)

        Subcase 2A: wshf_in belonging to the redirecting FB...
        ...are patched into ghist same cycle (redir_take bypass).

        Subcase 2B: " to FBs *younger* than the redirecting FB
        A redirect can only ever jump to an earlier index in the history (but,
        given a large enough GHR_BUF_SZ size, not so early that it wraps around
        the buffer to reach the wshf_in bit positions), so that the wshf_in bits
        belonging to any younger insns will NOT be in the rollback GHR_LEN window
        (they will be on the mispredicted path).

        e.g. if fb2 causes an s2_steer, then fb3 can be ignored.

        Subcase 2C: " to FBs *older* than the redirecting FB
        The most restrictive timing constraint is ensuring that fb1's wshf_in are
        reflected in hist when fb2 raises s2_steer:
        - 1 cycle separation between "redirecting fb (fb2)" and "fb demanding hist consistency (fb1)"
        (e.g. compared to 2-cycles between fb2 and fb0)
        - 2 cycles since "fb demanding hist consistency" presented its wshf_in bits to ghr
        (e.g. 3 cycles for s3_steer, and many more cycles for flush)

        cycle 0
        s1:fb1 -> s2:    -> s3:    -> ftq:
        fb1 presents bits to ghr, latched into ghist end-of-cycle

        cycle 1
        s1:fb2 -> s2:fb1 -> s3:    -> ftq:
        fb1 bits latched into hist end-of-cycle

        cycle 2
        s1:fb3 -> s2:fb2 -> s3:fb1 -> ftq:
        fb2 raises steer

        As you can see, older blocks will have shifted in their bits at
        least 1 cycle earlier.

        (FIXME: need to check these formally)
        */
        w       <= w_n;
        for (int i = 0; i < WPORTS; ++i) begin
            if (~w.en[i])
                continue;
            hist[w.idx[i]] <= w.val[i];
        end
        base    <= redir ? redir_base_n : base_n[wen_cnt];
        ghist   <= redir ? rd_ghist : ghist_win[WPORTS +: GHR_LEN];


        if (reset) begin
            hist    <= '0;
                // hist <= 'hACE1; // heuristic seed to avoid cold start
            base    <= '0;
            ghist   <= '0;
            w.en    <= '0;
        end

    end


// `ifdef FORMAL
//     always_ff @(posedge clock) begin
//         // runtime assertions
//         if (!reset) begin
//             logic [WPORTS-1:0] en_pred;
//             assert(!redir || !rslv[cidx[0]]) else
//                 $fatal("ghr: redir base %2d is already resolved", cidx[0]);
//             // assert(!redir || hist[redir_base] != redir_take) else
//             //     $fatal("ghr: redir take %b matches existing history", redir_take);
//             /* Reason for disabling this asssertion:
//             We must still perform redir even if the redir_take matches the hist record
//             (Q: How can this happen? A: target mismatch).

//             If we do not, we will fail to mark-resolve the dependent branches on the
//             mispredicted path and the ghr will stall forever. (This is also why we
//             cannot move to a simple "invert" hist value iff redir.)
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
        $display("  %3d | fetch: {en_cnt: %1d, pred: [%b, %b]}, redir: {%b, base: %2d, take: %b}",
            $time,
            wen_cnt,
            wshf_in[0],
            wshf_in[1],

            redir,
            redir_idx,
            redir_take
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