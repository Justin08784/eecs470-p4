`include "sys_defs.svh"

module ghr #(
    // parameter DEPTH     = 32,
    // parameter GHR_LEN   = 14,
    // parameter DEPTH     = 256,
    // parameter GHR_LEN   = 128,
    parameter DEPTH     = 128,
    parameter GHR_LEN   = 64,

    parameter CPORTS    = 1,    // number of branch resolutions
    parameter WPORTS    = 2,    // number of predictions that can be shifted in
    parameter RPORTS    = 1,    // number of ghr slices that must be read


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

    output  PTR base_n1,
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

    VEC hist; // {0=ntake, 1=take}
    logic [GHR_LEN-1:0] rslv; // resolved? i.e. not speculative?
    PTR base; // to youngest entry in the GHR window; (base-1) % DEPTH is the write head
    // VEC okay; // okay to overwrite?

    assign base_n1 = base - 1;

    generate
    VEC hist_n, hist_tmp;
    logic [GHR_LEN-1:0] rslv_n, rslv_tmp;
    

    logic [DEPTH+WPORTS-1:0] hist_fut;
    logic [GHR_LEN+WPORTS-1:0] rslv_fut;
    assign hist_fut[WPORTS +: DEPTH] = hist_n;
    for (genvar i = 0; i < WPORTS; ++i)
        assign hist_fut[WPORTS-1-i] = wpred[i];
    assign rslv_fut = {rslv_n, {WPORTS{1'b0}}};

    logic [WPORTS-1:0][GHR_LEN-1:0] rslv_slices;
    logic [WPORTS-1:0][DEPTH-1:0] hist_slices;
    for (genvar w = 0; w < WPORTS; ++w) begin
        assign rslv_slices[w] = rslv_fut[WPORTS-w +: GHR_LEN];
        assign hist_slices[w] = hist_fut[WPORTS-w +: DEPTH];
    end

    for (genvar i = 0; i < RPORTS; ++i) begin : GEN_GHR
        assign rghr[i][GHR_LEN-1:i] = hist;
        if (i > 0)
            assign rghr[i][i-1:0] = '0;
    end
    endgenerate

    // always_comb begin
    //     case (wen_cnt)
    //     1: begin
    //         hist_tmp = hist_fut[1 +: DEPTH];
    //         rslv_tmp = rslv_fut[1 +: GHR_LEN];
    //     end

    //     2: begin
    //         hist_tmp = hist_fut[0 +: DEPTH];
    //         rslv_tmp = rslv_fut[0 +: GHR_LEN];
    //     end

    //     default: begin
    //         hist_tmp = hist;
    //         rslv_tmp = rslv;
    //     end
    //     endcase
    // end



    logic [WPORTS-1:0] rdy;
    generate
    assign rdy[0] = rslv[GHR_LEN-1];
    for (genvar i = 1; i < WPORTS; ++i)
        assign rdy[i] = rslv[GHR_LEN-i-1] & rdy[i-1];
    assign rdy_scnt = $countones(rdy);
    endgenerate


    // logic [GHR_LEN-1:0] flush_rslv;
    logic [CPORTS-1:0][$clog2(GHR_LEN)-1:0] cadj;
    generate
    for (genvar c = 0; c < CPORTS; ++c)
        assign cadj[c] = cidx[c]-base;

    // for (genvar i = 0; i < GHR_LEN; ++i)
    //     assign flush_rslv[i] = i <= cadj[0];

    logic [GHR_LEN-1:0][GHR_LEN-1:0] rslv_fslices;
    logic [GHR_LEN-1:0][DEPTH-1:0] hist_fslices;
    for (genvar i = 0; i < GHR_LEN; ++i) begin
        assign rslv_fslices[i] = {'1, rslv[GHR_LEN-1:i]};
        assign hist_fslices[i] = {'0, hist[DEPTH-1:i]};
    end

    endgenerate

    // these _n's are for normal path updates (not for flush!)
    always_comb begin
        hist_n = hist;
        rslv_n = rslv;

        for (int i = 0; i < CPORTS; ++i) begin
            if (!cen[i])
                continue;
            rslv_n[cadj[i]] = 1;
        end
    end
    
    always_ff @(posedge clock) begin
        if (reset) begin
            rslv    <= '1;
            hist    <= '0;
            base    <= DEPTH-1; // TODO: change init to 0
            // base    <= '0;

        end else if (flush) begin
            // rslv[GHR_LEN-1:0] <= rslv[GHR_LEN-1:0] | flush_rslv;
            // rslv    <= {{GHR_LEN{1'b1}}, rslv} >> cadj[0];
            // hist    <= hist >> cadj[0];

            rslv    <= rslv_fslices[cadj[0]];
            hist    <= hist_fslices[cadj[0]];

            hist[0] <= ctake[0];
            base    <= cidx[0];

        end else begin
            // rslv_tmp = rslv_fut << wen_cnt;
            // hist_tmp = hist_fut << wen_cnt;

            // rslv    <= rslv_tmp;
            // hist    <= hist_tmp;
            rslv    <= rslv_slices[wen_cnt];
            hist    <= hist_slices[wen_cnt];
            base    <= base - wen_cnt;

        end

    end


`ifdef FORMAL
    always_ff @(posedge clock) begin
        // runtime assertions
        if (!reset) begin
            logic [WPORTS-1:0] en_pred;
            assert(!flush || !rslv[cidx[0] - base]) else
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
                assert(!cen[i] || !rslv[cidx[i] - base]) else
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
    
    // parameter DEPTH     = 32, // must be geq than 2*GHR_LEN and a power of 2
    // parameter GHR_LEN   = GHR_LEN,

    // parameter CPORTS    = NUM_FU_BRU,   // number of branch resolutions
    // parameter WPORTS    = NUM_BR_SLOTS, // number of predictions that can be shifted in
    // parameter RPORTS    = 1,            // number of ghr slices that must be read

    // parameter DEPTH     = 256,
    // parameter GHR_LEN   = 128,
