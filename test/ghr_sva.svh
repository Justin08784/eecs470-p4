`ifndef GHR_SVA_SVH
`define GHR_SVA_SVH

// check that the GHR_LEN-1 bits below-modulo after the base are resolved

module ghr_sva #(
    parameter DEPTH     = 32, // must be geq than 2*GHR_LEN and a power of 2
    parameter NUM_FU_BRU= `NUM_FU_BRU,
    parameter GHR_LEN   = GHR_LEN,
    parameter N         = `N,
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

    // misprediction flush (i.e. incorrect resolution)
    input           flush,
    input   PTR     flush_base, // base BEFORE shifting in current branch's pred
    input   logic   flush_take,

    // ex (correct resolutions)
    input   logic [NUM_FU_BRU-1:0] ex_en,
    input   PTR   [NUM_FU_BRU-1:0] ex_idx,

    // fetch
    input   logic [$clog2(N):0] f_en_cnt,
    input   logic [N-1:0]       f_pred,
    input   logic [$clog2(N):0] f_rdy_scnt,
    input   logic [N-1:0][GHR_LEN-1:0] f_ghr
);
    typedef struct packed {
        PTR base;
        VEC hist;
        VEC rslv;
    } GHR_STATE;

    GHR_STATE s, n;
    struct packed {
        logic [$clog2(N):0] f_rdy_scnt;
        logic [N-1:0][GHR_LEN-1:0] f_ghr;
    } sva_comb;

    always_ff @(posedge clock) begin
        if (reset)
            s <= '{
                base :  DEPTH-1,
                hist :  '0,
                rslv :  '1
            };
        else
            s <= n;
    end

    function automatic GHR_STATE ghr_step (
        input GHR_STATE             s,
        input logic                 flush,
        input PTR                   flush_base,
        input logic                 flush_take,
        input logic [NUM_FU_BRU-1:0]ex_en,
        input PTR   [NUM_FU_BRU-1:0]ex_idx,
        input logic [$clog2(N):0]   f_en_cnt,
        input logic [N-1:0]         f_pred
    );
        n = s;
        if (flush) begin
            for (PTR i = s.base; i != flush_base; ++i)
                n.rslv[i] = 1'b1;
            n.rslv[flush_base]= 1'b1;

            n.base = flush_base;
            n.hist[flush_base] = flush_take;

        end else begin
            for (int i = 0; i < NUM_FU_BRU; ++i) begin
                if (ex_en[i])
                    n.rslv[ex_idx[i]] = 1'b1;
            end

            for (int i = 0; i < f_en_cnt; ++i) begin
                PTR widx;
                widx = s.base - (i+1);
                n.hist[widx] = f_pred[i];
                n.rslv[widx] = 1'b0;
            end
            n.base = s.base - f_en_cnt;
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
            flush_base,
            flush_take,
            ex_en,
            ex_idx,
            f_en_cnt,
            f_pred
        );

        sva_comb.f_rdy_scnt = 0;
        for (int i = 0; i < N; ++i) begin
            PTR widx, last_dep;
            widx = s.base - (i+1);
            last_dep = widx - (GHR_LEN-1);
            if (!s.rslv[last_dep])
                break;

            ++sva_comb.f_rdy_scnt;
        end

        for (int i = 0; i < N; ++i) begin
            PTR idx;
            for (int j = 0; j < GHR_LEN; ++j) begin
                idx = s.base + j - i;
                sva_comb.f_ghr[i][j] = (j < i)
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
            $display("%2d, %2d", f_rdy_scnt, sva_comb.f_rdy_scnt);
            $display("%b, %b] %b, %b]", f_ghr[0],f_ghr[1],
            sva_comb.f_ghr[0], sva_comb.f_ghr[1]);
            // $display("used %d free %d us %d fs %d reset: %b", used, free, used_scnt, free_scnt, reset);
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        property f_rdy_correct;
            disable iff (reset)
            f_rdy_scnt == sva_comb.f_rdy_scnt;
        endproperty

        property f_ghr_correct;
            disable iff (reset)
            f_ghr == sva_comb.f_ghr;
        endproperty

        property hist_correct;
            disable iff (reset)
            hist == s.hist;
        endproperty
    endclocking

    match_f_rdy: assert property(cb.f_rdy_correct)
        else exit_on_error;
    match_f_ghr: assert property(cb.f_ghr_correct)
        else exit_on_error;
    match_hist: assert property(cb.hist_correct)
        else exit_on_error;


endmodule
`endif // GHR_SVA_SVH
