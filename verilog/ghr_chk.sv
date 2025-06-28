`include "sys_defs.svh"

module ghr_chk (
    input   clock,
    input   reset,

    // current state
    input   GHR_IDX base,
    input   logic[GHR_BUF_SZ-1:0] hist,

    // actions
    input   flush,
    input   GHR_IDX flush_ghr_base,

    input   `CNT_TYPE(N)    retire_en_cnt,
    input   GHR_IDX [N-1:0] retire_ghr_base,

    input   `CNT_TYPE(2)    wshf_in_en_cnt,
    input   logic[1:0]      wshf_in,

    input   logic   ubpu_ren,
    input   GHR_IDX ubpu_ghr_base
);
    typedef `IDX_TYPE(GHR_BUF_SZ) PTR;

    logic [GHR_BUF_SZ-1:0] rslv;
    logic [FH_LEN-1:0] rd_prehist_rslv;
        /* The ghr must be sized large enough so that new predictions shifted in
        by the BPU does not clobber history bits needed by a branch updating the BPU.
        
        This invariant is what allows us to to eliminate the expensive "rslv" maintenance logic. */

    for (genvar off = 0; off < FH_LEN; ++off)
        assign rd_prehist_rslv[off] = rslv[ubpu_ghr_base + PTR'(off)];

    always_ff @(posedge clock) begin
        if (reset)
            rslv <= '1;
        else if (flush) begin
            for (PTR i = base; ; --i) begin
                if (i == flush_ghr_base) begin
                    rslv[i] <= 1;
                    break;
                end

                rslv[i] <= 1;
            end

        end else begin
            for (int i = 0; i < wshf_in_en_cnt; ++i)
                rslv[base - (i+1)] <= 0;

            for (int i = 0; i < retire_en_cnt; ++i)
                rslv[retire_ghr_base[i]] <= 1;
        end
    end

    always_ff @(posedge clock) begin
        if (!reset) begin

            logic [1:0] en_pred;
            for (int i = 0; i < N; ++i)
                en_pred[i] = (i < wshf_in_en_cnt) & wshf_in[i];
            assert(!(|en_pred) || $onehot(en_pred)) else
                $fatal("ghr: en_pred (%b) is not one-hot", en_pred);

            // assert(!flush || !(|(rslv & flush_rslv))) else
            //     $fatal("ghr: flush resolved already resolved bits. rslv: %b, flush_rslv: %b", rslv, flush_rslv);

            // for (int i = 0; i < retire_en_cnt; ++i)
            //     assert(!rslv[retire_ghr_base[i]]) else
            //         $fatal("ghr: retiring branch already resolved");

            if (ubpu_ren)
                assert(&rd_prehist_rslv) else $fatal("ghr: history used for bpu update should be fully resolved.\
                base: %d, rslv: %b, rd_prehist_rslv: %b",
                    base,
                    rslv,
                    rd_prehist_rslv
                );
        end

    end

endmodule