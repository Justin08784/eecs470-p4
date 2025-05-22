`include "sys_defs.svh"

module ghr #(
    parameter DEPTH = 32, // must be greater than GHR_LEN and a power of 2
    type PTR = logic [$clog2(DEPTH)-1:0]
) (
    input           clock,
    input           reset,

    // misprediction flush (i.e. incorrect resolution)
    input           flush,
    input   PTR     flush_base,
    input   logic   flush_take,

    // ex (correct resolutions)
    input   logic [`NUM_FU_BRU-1:0] ex_en,
    input   PTR   [`NUM_FU_BRU-1:0] ex_idx,

    // fetch
    input   logic [$clog2(`N):0] f_en_cnt,
    input   logic [`N-1:0]       f_pred,
    output  logic [$clog2(`N):0] f_rdy_scnt,
    output  logic [`N-1:0][GHR_LEN-1:0] f_ghr
);
    function automatic PTR decr(input PTR p, input int unsigned k);
        return p < k ? p + DEPTH - k : p - k;
    endfunction

    function automatic PTR rotr(input logic [DEPTH-1:0] v, input PTR sh);
        return (v >> sh) | (v << (DEPTH - sh));
    endfunction

    logic [DEPTH-1:0] rslv; // resolved? i.e. not speculative?
    logic [DEPTH-1:0] hist; // {0=ntake, 1=take}
    PTR base;

    logic [DEPTH-1:0] okay; // okay to overwrite?

    initial begin
        assert(`N < DEPTH) else
            $fatal("GHR: N (%0d) must be smaller than DEPTH (%0d)",`N,DEPTH);

        assert ((DEPTH != 0) && ((DEPTH & (DEPTH - 1)) == 0))
            else $fatal("GHR DEPTH must be a power of 2");

        assert (DEPTH >= GHR_LEN)
            else $fatal("GHR DEPTH must be >= GHR_LEN");
    end

    always_comb begin
        logic [`N-1:0][DEPTH-1:0] tmp;

        for (int i = 0; i < `N; ++i) begin
            // tmp[i] = (i > 0)
            //     ? tmp[i-1] << 1 | f_pred[i-1]
            //     : rotr(hist, base) & ~GHR_LEN'(1);
            // f_ghr[i] = tmp[i][GHR_LEN:1];

            tmp[i] = (i > 0)
                ? tmp[i-1] << 1
                : rotr(hist, base) & ~GHR_LEN'(1); // clear LSB (write head/base)
            f_ghr[i] = tmp[i][GHR_LEN:1];
        end

        // cannot retire hist bit if leftmost branch in GHR window is unresolved
        // (otherwise, on mispredict of that branch, the current bit will be
        // lost/"shifted out" and unrecoverable)
        okay = rotr(rslv, GHR_LEN - 1);

        f_rdy_scnt = 0;
        for (int i = 0; i < `N; ++i) begin
            if (!okay[decr(base, i)])
                break;
            ++f_rdy_scnt;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            rslv <= '1;
            // hist <= 'hACE1; // heuristic seed to avoid cold start
            hist <= '0;
            base <= DEPTH-1;

        end else if (flush) begin
            rslv[flush_base] <= 1;
            hist[flush_base] <= flush_take;
            base <= flush_base;

        end else begin
            for (int i = 0; i < `NUM_FU_BRU; ++i) begin
                if (!ex_en[i])
                    continue;
                rslv[ex_idx[i]] <= 1;
            end

            for (int i = 0; i < f_en_cnt; ++i) begin
                int idx;
                idx = decr(base, i);
                rslv[idx] <= 0;
                hist[idx] <= f_pred[i];
            end
            base <= decr(base, f_en_cnt);
        end
    end
endmodule

// cool indexing trick

// if (base >= GHR_LEN)
//     f_ghr[0] = hist[base-1 -: GHR_LEN];
// else
//     f_ghr[0] = {
//         hist[DEPTH-1 -: (GHR_LEN-base)], // this illegal
//         hist[base-1 -: GHR_LEN]
//     };