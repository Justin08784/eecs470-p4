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

    function automatic logic [DEPTH-1:0] rotr(input logic [DEPTH-1:0] v, int sh);
        int sh_mod;
        sh_mod = sh % DEPTH;
        return (v >> sh_mod) | (v << (DEPTH - sh_mod));
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
        f_ghr[0] = rotr(hist, base + 1);
        for (int i = 0; i < `N-1; ++i)
            f_ghr[i+1] = f_ghr[i] << 1 | f_pred[i];

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
            hist <= (DEPTH)'hACE1; // heuristic seed to avoid cold start
            base <= DEPTH-1;

        end else if (flush) begin
            rslv[flush_base] <= 1;
            hist[flush_base] <= flush_take;
            base <= decr(flush_base, 1);

        end else begin
            for (int i = 0; i < `NUM_FU_BRU; ++i) begin
                if (!ex_en[i])
                    continue;
                rslv[ex_idx[i]] <= 1;
            end

            for (int i = 0; i < f_en_cnt; ++i) begin
                rslv[decr(base, i)] <= 0;
                hist[decr(base, i)] <= f_pred[i];
            end
            base <= decr(base, f_en_cnt);
        end
    end
endmodule
