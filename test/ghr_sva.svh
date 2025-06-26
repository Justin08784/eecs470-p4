`include "sys_defs.svh"

`ifndef GHR_SVA_SVH
`define GHR_SVA_SVH

// check that the GHR_LEN-1 bits below-modulo after the base are resolved

module ghr_sva #(
    parameter DEPTH     = 32, // must be geq than 2*GHR_LEN and a power of 2
    parameter GHR_LEN   = GHR_LEN,
    parameter FH_LEN    = 1,

    parameter WPORTS    = NUM_BR_SLOTS, // number of predictions that can be shifted in
    type VEC = logic [DEPTH-1:0],
    type PTR = logic [$clog2(DEPTH)-1:0]
) (
    input   VEC hist,
    input   logic [GHR_LEN-1:0] ghist,
    input   PTR base,
    input   logic [FH_LEN-1:0] fh,
    input   logic [FH_LEN-1:0] raw_fh,

    input   clock,
    input   reset,

    // misprediction flush
    input   flush,
    input   logic   flush_take,
    input   PTR     flush_idx, // base BEFORE shifting in current branch's pred

    // fetch
    input   `CNT_TYPE(WPORTS)   wen_cnt,
    input   logic [WPORTS-1:0]  wshf_in,
    input   PTR     base_n1,

    // retire
    input   PTR     ridx,
    input   logic [GHR_LEN-1:0] rd_ghist
);
    typedef struct packed {
        VEC hist;
        PTR base;
    } GHR_STATE;
    // int nres [$]; // non resolved base pointers (an alternative way to construct rslv)

    GHR_STATE s, n;
    struct packed {
        PTR base_n1;
        logic [GHR_LEN-1:0] rd_ghist;
    } sva_comb;

    always_ff @(posedge clock) begin
        if (reset) begin
            s <= '0;

            // nres = {};
        end else begin
            s <= n;

            // if (flush) begin
            //     while (`TRUE) begin
            //         if (nres[$] == cidx[0]) begin
            //             nres.pop_back();
            //             break;
            //         end

            //         if (nres.size() == 0) begin
            //             $error("What the fuck");
            //             break;
            //         end

            //         nres.pop_back();
            //     end

            // end else begin
            //     for (int i = 0; i < CPORTS; ++i) begin
            //         if (!cen[i])
            //             continue;
            //         foreach (nres[j]) begin
            //             if (nres[j] == cidx[i]) begin
            //                 nres.delete(j);
            //                 break;
            //             end
            //         end
            //     end

            //     for (int i = 0; i < wen_cnt; ++i) begin
            //         PTR idx;
            //         idx = s.base - (i+1);
            //         nres.push_back(idx);
            //     end
            // end

        end
    end

    function automatic GHR_STATE ghr_step (
        input GHR_STATE s
    );
        n = s;
        if (flush) begin
            n.base = flush_idx;
            n.hist[flush_idx] = flush_take;

        end else begin
            n.base = s.base - wen_cnt;
            for (int i = 0; i < wen_cnt; ++i) begin
                PTR idx;
                idx = s.base - (i+1);
                n.hist[idx] = wshf_in[i];
            end
        end

        return n;
    endfunction

        
    logic ghist_eq;
    PTR rd_ghist_base;
    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin
        n = ghr_step(s);

        rd_ghist_base = flush ? flush_idx : ridx;
        for (int i = 0; i < GHR_LEN; ++i) begin
            PTR idx;
            idx = rd_ghist_base + i;
            sva_comb.rd_ghist[i] = s.hist[idx];
        end
        if (flush)
            sva_comb.rd_ghist[0] = flush_take;

        ghist_eq = 1;
        for (int i = 0; i < GHR_LEN; ++i) begin
            PTR idx;
            idx = base + i;
            ghist_eq &= ghist[i] == hist[idx];
        end

        @(posedge clock);
        @(negedge clock);
    end
    end

    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            // $display("%b, %b", n.hist, hist);
            // $display("%2d, %2d", rdy_scnt, sva_comb.rdy_scnt);
            // $display("%b, %b] %b, %b]", rghr[0],rghr[1],
            // sva_comb.rghr[0], sva_comb.rghr[1]);
            // $display("used %d free %d us %d fs %d reset: %b", used, free, used_scnt, free_scnt, reset);
            $finish;
        end
    endtask

    // function automatic logic nres_iff_rslv();
    //     VEC shadow_rslv;
    //     shadow_rslv = '1;
    //     foreach (nres[i])
    //         shadow_rslv[nres[i]] = 1'b0;
    //     return rslv == shadow_rslv;
    // endfunction

    // function automatic logic is_nrz_resolved();
    //     /*
    //     nrz (non-recoverable zone) := def. is a GHR_LEN-1 length window of the GHR.
    //     If an index is in the nrz, then the GHR based at it (i.e. its youngest
    //     entry is that index) is missing at least one entry (more precisely, the
    //     GHR base pointer wrote past it), hence "non-recoverable". The nrz shifts
    //     -modulo whenever we decrement the base.

    //     We must only allow branches into the nrz that do not need to recover its GHR or,
    //     in other words, branches that are resolved. If a non-resolved branch enters
    //     the nrz, it becomes impossible to rebuild the full GHR rooted at that branch
    //     if it resolves to a mispredict.

    //     If a branch in the nrz is not fully resolved, this implies that the
    //     base pointer–– at some earlier time–– illegally advanced/decremented.
    //     */

    //     logic [GHR_LEN-2:0] nrz_rslv;
    //     for (int i = 0; i <= GHR_LEN-2; ++i) begin
    //         PTR idx;
    //         idx = base - (i+1);
    //         nrz_rslv[i] = rslv[idx];
    //     end

    //     return &nrz_rslv;
    // endfunction

    clocking cb @(posedge clock);
        // property rdy_correct;
        //     disable iff (reset)
        //     rdy_scnt == sva_comb.rdy_scnt;
        // endproperty

        property ghist_correct;
            disable iff (reset)
            ghist_eq;
        endproperty

        property rd_ghist_correct;
            disable iff (reset)
            rd_ghist == sva_comb.rd_ghist;
        endproperty

        property fh_correct;
            disable iff (reset)
            raw_fh == fh;
        endproperty

        // property rslv_correct;
        //     disable iff (reset)
        //     rslv == s.rslv;
        // endproperty

        property hist_correct;
            disable iff (reset)
            hist == s.hist;
        endproperty

        property base_correct;
            disable iff (reset)
            base == s.base;
        endproperty

        // property rslv_correct_wrt_nres;
        //     disable iff (reset)
        //     nres_iff_rslv();
        // endproperty

        // property nrz_rslvd;
        //     disable iff (reset)
        //     is_nrz_resolved();
        // endproperty
    endclocking

    // match_rdy: assert property(cb.rdy_correct)
    //     else exit_on_error;
    match_ghist: assert property(cb.ghist_correct)
        else exit_on_error;
    match_rd_ghist: assert property(cb.rd_ghist_correct)
        else exit_on_error;
    match_fh: assert property(cb.fh_correct)
        else exit_on_error;
    // match_rslv: assert property(cb.rslv_correct)
    //     else exit_on_error;
    match_hist: assert property(cb.hist_correct)
        else exit_on_error;
    match_base: assert property(cb.base_correct)
        else exit_on_error;
    // nrz_rslv: assert property(cb.nrz_rslvd)
    //     else exit_on_error;
    // nres_rslv: assert property(cb.rslv_correct_wrt_nres)
    //     else exit_on_error;


endmodule
`endif // GHR_SVA_SVH
