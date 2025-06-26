`include "sys_defs.svh"

`ifndef GHR_SVA_SVH
`define GHR_SVA_SVH

// check that the GHR_LEN-1 bits below-modulo after the base are resolved

module ghr_sva #(
    parameter DEPTH     = 32, // must be geq than 2*GHR_LEN and a power of 2
    parameter GHR_LEN   = GHR_LEN,

    parameter CPORTS    = NUM_FU_BRU,   // number of branch resolutions
    parameter WPORTS    = NUM_BR_SLOTS, // number of predictions that can be shifted in
    parameter RPORTS    = 1,            // number of ghr slices that must be read
    type VEC = logic [DEPTH-1:0],
    type PTR = logic [$clog2(DEPTH)-1:0]
) (
    input   VEC     rslv,
    input   VEC     hist,
    input   PTR     base,
    input   VEC     base_oh,
    input   VEC     okay,

    input           clock,
    input           reset,
    input           flush,

    // ex (resolutions)
    input   logic [CPORTS-1:0]  cen,
    input   logic [CPORTS-1:0]  ctake,
    input   PTR   [CPORTS-1:0]  cidx,

    // fetch
    input   `CNT_TYPE(WPORTS)   wen_cnt, rdy_scnt,
    input   logic [WPORTS-1:0]  wpred,
    input   logic [RPORTS-1:0][GHR_LEN-1:0] rghr
);
    typedef struct packed {
        PTR base;
        VEC hist;
        VEC rslv;
    } GHR_STATE;
    int nres [$]; // non resolved base pointers (an alternative way to construct rslv)

    GHR_STATE s, n;
    struct packed {
        logic [$clog2(WPORTS):0] rdy_scnt;
        logic [RPORTS-1:0][GHR_LEN-1:0] rghr;
    } sva_comb;

    always_ff @(posedge clock) begin
        if (reset) begin
            s <= '{
                base :  DEPTH-1,
                hist :  '0,
                rslv :  '1
            };

            nres = {};
        end else begin
            s <= n;

            if (flush) begin
                while (`TRUE) begin
                    if (nres[$] == cidx[0]) begin
                        nres.pop_back();
                        break;
                    end

                    if (nres.size() == 0) begin
                        $error("What the fuck");
                        break;
                    end

                    nres.pop_back();
                end

            end else begin
                for (int i = 0; i < CPORTS; ++i) begin
                    if (!cen[i])
                        continue;
                    foreach (nres[j]) begin
                        if (nres[j] == cidx[i]) begin
                            nres.delete(j);
                            break;
                        end
                    end
                end

                for (int i = 0; i < wen_cnt; ++i) begin
                    PTR idx;
                    idx = s.base - (i+1);
                    nres.push_back(idx);
                end
            end

        end
    end

    function automatic GHR_STATE ghr_step (
        input GHR_STATE             s,
        input logic                 flush,
        input logic [CPORTS-1:0]    cen,
        input PTR   [CPORTS-1:0]    cidx,
        input logic [$clog2(WPORTS):0]wen_cnt,
        input logic [WPORTS-1:0]    wpred
    );
        n = s;
        if (flush) begin
            for (PTR i = s.base; i != cidx[0]; ++i)
                n.rslv[i] = 1'b1;
            n.rslv[cidx[0]]= 1'b1;

            n.base = cidx[0];
            n.hist[cidx[0]] = ctake[0];

        end else begin
            for (int i = 0; i < CPORTS; ++i) begin
                if (cen[i])
                    n.rslv[cidx[i]] = 1'b1;
            end

            for (int i = 0; i < wen_cnt; ++i) begin
                PTR widx;
                widx = s.base - (i+1);
                n.hist[widx] = wpred[i];
                n.rslv[widx] = 1'b0;
            end
            n.base = s.base - wen_cnt;
        end

        return n;

    endfunction

    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin
        n = ghr_step(
            s,
            flush,
            cen,
            cidx,
            wen_cnt,
            wpred
        );

        sva_comb.rdy_scnt = 0;
        for (int i = 0; i < WPORTS; ++i) begin
            PTR widx, last_dep;
            widx = s.base - (i+1);
            last_dep = widx - (GHR_LEN-1);
            if (!s.rslv[last_dep])
                break;

            ++sva_comb.rdy_scnt;
        end

        for (int i = 0; i < RPORTS; ++i) begin
            PTR idx;
            for (int j = 0; j < GHR_LEN; ++j) begin
                idx = s.base + j - i;
                sva_comb.rghr[i][j] = (j < i)
                    ? 1'b0
                    : s.hist[idx];
            end
        end

        @(posedge clock);
        @(negedge clock);
    end
    end

    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            $display("%b, %b", n.hist, hist);
            $display("%2d, %2d", rdy_scnt, sva_comb.rdy_scnt);
            $display("%b, %b] %b, %b]", rghr[0],rghr[1],
            sva_comb.rghr[0], sva_comb.rghr[1]);
            // $display("used %d free %d us %d fs %d reset: %b", used, free, used_scnt, free_scnt, reset);
            $finish;
        end
    endtask

    function automatic logic nres_iff_rslv();
        VEC shadow_rslv;
        shadow_rslv = '1;
        foreach (nres[i])
            shadow_rslv[nres[i]] = 1'b0;
        return rslv == shadow_rslv;
    endfunction

    function automatic logic is_nrz_resolved();
        /*
        nrz (non-recoverable zone) := def. is a GHR_LEN-1 length window of the GHR.
        If an index is in the nrz, then the GHR based at it (i.e. its youngest
        entry is that index) is missing at least one entry (more precisely, the
        GHR base pointer wrote past it), hence "non-recoverable". The nrz shifts
        -modulo whenever we decrement the base.

        We must only allow branches into the nrz that do not need to recover its GHR or,
        in other words, branches that are resolved. If a non-resolved branch enters
        the nrz, it becomes impossible to rebuild the full GHR rooted at that branch
        if it resolves to a mispredict.

        If a branch in the nrz is not fully resolved, this implies that the
        base pointer–– at some earlier time–– illegally advanced/decremented.
        */

        logic [GHR_LEN-2:0] nrz_rslv;
        for (int i = 0; i <= GHR_LEN-2; ++i) begin
            PTR idx;
            idx = base - (i+1);
            nrz_rslv[i] = rslv[idx];
        end

        return &nrz_rslv;
    endfunction

    clocking cb @(posedge clock);
        property rdy_correct;
            disable iff (reset)
            rdy_scnt == sva_comb.rdy_scnt;
        endproperty

        property rghr_correct;
            disable iff (reset)
            rghr == sva_comb.rghr;
        endproperty

        property rslv_correct;
            disable iff (reset)
            rslv == s.rslv;
        endproperty

        property hist_correct;
            disable iff (reset)
            hist == s.hist;
        endproperty

        property base_correct;
            disable iff (reset)
            base == s.base && base_oh == (1 << s.base);
        endproperty

        property rslv_correct_wrt_nres;
            disable iff (reset)
            nres_iff_rslv();
        endproperty

        property nrz_rslvd;
            disable iff (reset)
            is_nrz_resolved();
        endproperty
    endclocking

    match_rdy: assert property(cb.rdy_correct)
        else exit_on_error;
    match_rghr: assert property(cb.rghr_correct)
        else exit_on_error;
    match_rslv: assert property(cb.rslv_correct)
        else exit_on_error;
    match_hist: assert property(cb.hist_correct)
        else exit_on_error;
    match_base: assert property(cb.base_correct)
        else exit_on_error;
    nrz_rslv: assert property(cb.nrz_rslvd)
        else exit_on_error;
    nres_rslv: assert property(cb.rslv_correct_wrt_nres)
        else exit_on_error;


endmodule
`endif // GHR_SVA_SVH
