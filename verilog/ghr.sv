`include "sys_defs.svh"

module ghr #(
    parameter DEPTH     = 32, // must be geq than 2*GHR_LEN and a power of 2
    parameter GHR_LEN   = GHR_LEN,

    parameter CPORTS    = NUM_FU_BRU,   // number of branch resolutions
    parameter WPORTS    = NUM_BR_SLOTS, // number of predictions that can be shifted in
    parameter RPORTS    = 1,            // number of ghr slices that must be read
    type VEC = logic [DEPTH-1:0],
    type PTR = logic [$clog2(DEPTH)-1:0]
) (
    input   clock,
    input   reset,
    input   flush,

    // misprediction flush (i.e. incorrect resolution)
    // input   logic   flush_take,
    // input   PTR     flush_base, // base BEFORE shifting in current branch's pred

    // ex (resolutions)
    input   logic [CPORTS-1:0]  cen,
    input   logic [CPORTS-1:0]  ctake,
    input   PTR   [CPORTS-1:0]  cidx,

    // fetch
    output  `CNT_TYPE(WPORTS)   rdy_scnt,
    input   `CNT_TYPE(WPORTS)   wen_cnt,
    input   logic [WPORTS-1:0]  wpred,

    output  PTR [WPORTS:0]      base_n,
    output  logic[RPORTS-1:0][GHR_LEN-1:0] rghr
);
    initial begin
        assert(N < DEPTH) else // FIXME
            $fatal("GHR: N (%0d) must be smaller than DEPTH (%0d)", N, DEPTH);

        assert ((DEPTH != 0) && ((DEPTH & (DEPTH - 1)) == 0))
            else $fatal("GHR DEPTH must be a power of 2");

        assert (DEPTH >= 2*GHR_LEN)
            else $fatal("GHR DEPTH must be >= 2*GHR_LEN");
    end

    function automatic VEC rotl(input VEC v, input PTR sh);
        // This is so fucking elegant I'm going to cry
        logic [2*DEPTH-1:0] dv;
        dv = {v, v} << sh;
        return dv[2*DEPTH-1:DEPTH];
    endfunction

    function automatic VEC rotr(input VEC v, input PTR sh);
        logic [2*DEPTH-1:0] dv;
        dv = {v, v} >> sh;
        return dv[DEPTH-1:0];
    endfunction

    function automatic VEC get_arc(input PTR lo, input PTR hi);
        // "in-between" circular mask". low inclusive AND high inclusive
        // V1
        logic wrap;
        VEC rv;

        wrap = lo > hi;
        for (int i = 0; i < DEPTH; ++i) begin
            rv[i] = wrap
                ? ((i >= lo) || (i <= hi))
                : ((i >= lo) && (i <= hi));
        end

        return rv;

        // V2
        // VEC rv, ones_z0, gt, lt, flush_set;
        // ones_z0 = {{DEPTH-1{1'b1}}, 1'b0};
        
        // gt =   ones_z0 << lo;
        // lt = ~(ones_z0 << hi);

        // rv = |(gt & lt)
        //     ? gt & lt
        //     : gt | lt;

        // return rv;
    endfunction

    VEC rslv; // resolved? i.e. not speculative?
    VEC hist; // {0=ntake, 1=take}
    PTR base; // to youngest entry in the GHR window; (base-1) % DEPTH is the write head
    VEC base_oh;
    VEC okay; // okay to overwrite?

    VEC [WPORTS:0]      base_oh_n;      // oh's to prescribe writes
    VEC [GHR_LEN-1:0]   base_oh_win;    // oh's to prescribe GHR window
    generate
    assign base_n[0] = base;
    for (genvar k = 1; k < WPORTS+1; ++k) begin
        assign base_n[k] = base - PTR'(k); // FIXME: do ucast on k
    end

    assign base_oh_n[0] = base_oh;
    for (genvar k = 1; k < WPORTS+1; ++k) begin
        assign base_oh_n[k] = rotr(base_oh, k);
    end

    assign base_oh_win[0] = base_oh;
    for (genvar k = 1; k < GHR_LEN; ++k) begin
        assign base_oh_win[k] = rotl(base_oh, k);
    end
    endgenerate


    generate
    for (genvar i = 0; i < RPORTS; ++i) begin : GEN_GHR
        for (genvar j = 0; j < GHR_LEN; ++j) begin : GEN_BIT
            if (j < i)
                assign rghr[i][j] = 1'b0; // new bits; default ntaken
            else
                assign rghr[i][j] = |(hist & base_oh_win[j-i]);
        end
    end
    endgenerate


    logic [WPORTS-1:0] rdy;
    always_comb begin
        // if we advance base, then we will push 1 more branch into the nrz.
        // we must ensure said branch is resolved (and thus does not require recovery).
        okay = rotl(rslv, GHR_LEN-1);

        rdy[0] = |(okay & base_oh_n[1]);
        for (int i = 1; i < WPORTS; ++i)
            rdy[i] = rdy[i-1] && |(okay & base_oh_n[i+1]);
        rdy_scnt = $countones(rdy);
    end

    // these _n's are for normal path updates (not for flush!)
    VEC hist_n;
    VEC rslv_n;
    always_comb begin
        hist_n = hist;
        rslv_n = rslv;

        for (int i = 0; i < wen_cnt; ++i) begin
            if (wpred[i])
                hist_n |= base_oh_n[i+1];
            else
                hist_n &= ~base_oh_n[i+1];

            rslv_n &= ~base_oh_n[i+1];
        end

        for (int i = 0; i < CPORTS; ++i) begin
            if (!cen[i])
                continue;
            rslv_n[cidx[i]] = 1;
        end
    end
    
    always_ff @(posedge clock) begin
        if (reset) begin
            rslv    <= '1;
            // hist <= 'hACE1; // heuristic seed to avoid cold start
            hist    <= '0;
            base    <= DEPTH-1;
            base_oh <= VEC'(1) << (DEPTH-1);

        end else if (flush) begin
            rslv    <= rslv | get_arc(base, cidx[0]);
                // everything in rlsv[flush_base,..(mod+), base] must be set
            hist[cidx[0]] <= ctake[0];
            base    <= cidx[0];
            base_oh <= VEC'(1) << cidx[0];

        end else begin
            rslv    <= rslv_n;
            hist    <= hist_n;
            base    <= base_n[wen_cnt];
            base_oh <= base_oh_n[wen_cnt];

        end

    end


`ifdef FORMAL
    always_ff @(posedge clock) begin
        // runtime assertions
        if (!reset) begin
            logic [WPORTS-1:0] en_pred;
            assert(!flush || !rslv[cidx[0]]) else
                $fatal("ghr: flush base %2d is already resolved", cidx[0]);
            // assert(!flush || hist[flush_base] != flush_take) else
            //     $fatal("ghr: flush take %b matches existing history", flush_take);
            /* Reason for disabling this asssertion:
            We must still perform flush even if the flush_take matches the hist record
            (Q: How can this happen? A: target mismatch).

            If we do not, we will fail to mark-resolve the dependent branches on the
            mispredicted path and the ghr will stall forever. (This is also why we
            cannot move to a simple "invert" hist value iff flush.)
            */

            for (int i = 0; i < CPORTS; ++i) begin
                assert(!cen[i] || !rslv[cidx[i]]) else
                    $fatal("ghr: ex_idx %2d is already resolved", cidx[i]);
            end
            // assert(!(|f_pred) || $onehot(f_pred)) else
            //     $fatal("ghr: f_pred (%b) is not one-hot", f_pred);

            en_pred = '0;
            for (int i = 0; i < wen_cnt; ++i)
                en_pred[i] = wpred[i];
            assert(!(|en_pred) || $onehot(en_pred)) else
                $fatal("ghr: en_pred (%b) is not one-hot", en_pred);
        end

    end
`endif


`ifdef DEBUG
    task print_ghr;
        $display(">> ghr >>");
        $display("  %3d | fetch: {en_cnt: %1d, pred: [%b, %b]}, ex_in: {en: %b, idx: %2d}, flush: {%b, base: %2d, take: %b}",
            $time,
            wen_cnt,
            wpred[0],
            wpred[1],
            cen,
            cidx,
            flush,
            cidx[0],
            ctake[0],
        );

        // foreach(sva.nres[i])
        //     $display("  nres[%2d]: %2d", i, sva.nres[i]);

        $display("got: ghr: %b, hist: %b, rslv: %b, base: %2d (f_rdy_scnt: %2d)",
            rghr,
            hist,
            rslv,
            base,
            rdy_scnt
        );
        $display("<< ghr <<");
    endtask
`endif

endmodule