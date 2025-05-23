`include "sys_defs.svh"

module ghr #(
    parameter DEPTH     = 32, // must be greater than GHR_LEN and a power of 2
    parameter NUM_FU_BRU= `NUM_FU_BRU,
    parameter GHR_LEN   = GHR_LEN,
    parameter N         = `N,
    type VEC = logic [DEPTH-1:0],
    type PTR = logic [$clog2(DEPTH)-1:0]
) (
    input           clock,
    input           reset,

    // misprediction flush (i.e. incorrect resolution)
    input           flush,
    input   PTR     flush_base,
    input   logic   flush_take,

    // ex (correct resolutions)
    input   logic [NUM_FU_BRU-1:0] ex_en,
    input   PTR   [NUM_FU_BRU-1:0] ex_idx,

    // fetch
    input   logic [$clog2(N):0] f_en_cnt,
    input   logic [N-1:0]       f_pred,
    output  logic [$clog2(N):0] f_rdy_scnt,
    output  logic [N-1:0][GHR_LEN-1:0] f_ghr
);
    initial begin
        assert(N < DEPTH) else
            $fatal("GHR: N (%0d) must be smaller than DEPTH (%0d)", N, DEPTH);

        assert ((DEPTH != 0) && ((DEPTH & (DEPTH - 1)) == 0))
            else $fatal("GHR DEPTH must be a power of 2");

        assert (DEPTH >= GHR_LEN)
            else $fatal("GHR DEPTH must be >= GHR_LEN");
    end

    function automatic PTR decr(input PTR p, input int unsigned k);
        return p < k ? p + DEPTH - k : p - k;
    endfunction

    function automatic VEC rotl(input VEC v, input PTR sh);
        return (v << sh) | (v >> (DEPTH - sh));
    endfunction

    function automatic VEC rotr(input VEC v, input PTR sh);
        return (v >> sh) | (v << (DEPTH - sh));
    endfunction

    VEC rslv; // resolved? i.e. not speculative?
    VEC hist; // {0=ntake, 1=take}
    PTR base;
    VEC base_oh;
    VEC okay; // okay to overwrite?


    VEC [N:0]           base_oh_n;      // oh's to prescribe writes
    VEC [GHR_LEN-1:0]   base_oh_win;    // oh's to prescribe GHR window
    generate
    assign base_oh_n[0] = base_oh;
    for (genvar k = 1; k < N+1; ++k) begin
        assign base_oh_n[k] = rotr(base_oh, k);
    end

    assign base_oh_win[0] = base_oh;
    for (genvar k = 1; k < GHR_LEN; ++k) begin
        assign base_oh_win[k] = rotl(base_oh, k);
    end
    endgenerate


    generate
    for (genvar i = 0; i < N; ++i) begin : GEN_GHR
        for (genvar j = 0; j < GHR_LEN; ++j) begin : GEN_BIT
            if (j < i)
                assign f_ghr[i][j] = 1'b0; // new bits; default ntaken
            else
                assign f_ghr[i][j] = |(hist & base_oh_win[j-i]);
        end
    end
    endgenerate


    always_comb begin
        logic [N-1:0] rdy;

        // cannot retire hist bit if leftmost branch in GHR window is unresolved
        // (otherwise, on mispredict of that branch, the current bit will be
        // lost/"shifted out" and unrecoverable)
        okay = rotl(rslv, GHR_LEN-1);

        rdy[0] = |(okay & base_oh_n[1]);
        for (int i = 1; i < N; ++i)
            rdy[i] = rdy[i-1] && |(okay & base_oh_n[i+1]);
        f_rdy_scnt = $countones(rdy);
    end

    // these _n's are for normal path updates (not for flush!)
    VEC hist_n;
    VEC rslv_n;
    always_comb begin
        hist_n = hist;
        rslv_n = rslv;

        for (int i = 0; i < f_en_cnt; ++i) begin
            if (f_pred[i])
                hist_n |= base_oh_n[i+1];
            else
                hist_n &= ~base_oh_n[i+1];

            rslv_n &= ~base_oh_n[i+1];
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            rslv    <= '1;
            // hist <= 'hACE1; // heuristic seed to avoid cold start
            hist    <= '0;
            base    <= DEPTH-1;
            base_oh <= 1 << (DEPTH-1);

        end else if (flush) begin
            rslv[flush_base]<= 1;
            hist[flush_base]<= flush_take;
            base            <= flush_base;
            base_oh         <= 1 << flush_base;
            /* Do we need to re-set (i.e set high) the bits
            between base and flush_base? c.f. dep table in bman */

        end else begin
            for (int i = 0; i < NUM_FU_BRU; ++i) begin
                if (!ex_en[i])
                    continue;
                rslv[ex_idx[i]] <= 1;
            end

            rslv    <= rslv_n;
            hist    <= hist_n;
            base    <= decr(base, f_en_cnt);
            base_oh <= base_oh_n[f_en_cnt];
        end
    end
endmodule

// cool part-slice indexing trick
// if (base >= GHR_LEN)
//     f_ghr[0] = hist[base-1 -: GHR_LEN];
// else
//     f_ghr[0] = {
//         hist[DEPTH-1 -: (GHR_LEN-base)], // this is illegal
//         hist[base-1 -: GHR_LEN]
//     };