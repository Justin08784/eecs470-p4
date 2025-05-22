`include "sys_defs.svh"

module ghr #(
    parameter DEPTH = 32, // must be greater than GHR_LEN and a power of 2
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

    function automatic logic [DEPTH-1:0] rotr(input logic [DEPTH-1:0] v, input PTR sh);
        return (v >> sh) | (v << (DEPTH - sh));
    endfunction

    logic [DEPTH-1:0] rslv; // resolved? i.e. not speculative?
    logic [DEPTH-1:0] hist; // {0=ntake, 1=take}
    PTR base;
    VEC base_oh;
    VEC [`N:0] base_oh_n;

    logic [DEPTH-1:0] okay; // okay to overwrite?

    generate
    assign base_oh_n[0] = base_oh;
    for (genvar i = 1; i < `N+1; ++i) begin
        assign base_oh_n[i] = rotr(base_oh, i);
    end
    endgenerate

    initial begin
        assert(`N < DEPTH) else
            $fatal("GHR: N (%0d) must be smaller than DEPTH (%0d)",`N,DEPTH);

        assert ((DEPTH != 0) && ((DEPTH & (DEPTH - 1)) == 0))
            else $fatal("GHR DEPTH must be a power of 2");

        assert (DEPTH >= GHR_LEN)
            else $fatal("GHR DEPTH must be >= GHR_LEN");
    end


    // VEC tmp;
    // assign tmp = rotr(hist, base);
    // generate
    // for (genvar i = 0; i < `N; ++i) begin
    //     assign f_ghr[i] = {tmp[1 +: GHR_LEN-i], {i{1'b0}}};
    // end
    // endgenerate

    localparam int MAX_OFF = GHR_LEN + `N - 1;   // furthest bit we ever touch

    VEC [MAX_OFF:0] base_oh_rot;

    assign base_oh_rot[0] = base_oh;
    generate
    for (genvar k = 1; k < MAX_OFF+1; ++k) begin
        assign base_oh_rot[k] = rotr(base_oh, k);
    end
    endgenerate

    generate
    for (genvar i = 0; i < `N; ++i) begin : GEN_GHR
        for (genvar j = 0; j < GHR_LEN; ++j) begin : GEN_BIT
            localparam int off = i + j + 1;       // 1 ... MAX_off
            if (j < i) begin
                assign f_ghr[i][j] = 1'b0;          // still speculative, force 0
            end else begin
                // single bit:  hist[ base – off ]
                assign f_ghr[i][j] = |(hist & base_oh_rot[off]);
            end
        end
    end
    endgenerate


    always_comb begin
        // logic [`N-1:0][DEPTH-1:0] tmp;
        logic [`N-1:0] rdy;

        // for (int i = 0; i < `N; ++i) begin
        //     // tmp[i] = (i > 0)
        //     //     ? tmp[i-1] << 1 | f_pred[i-1]
        //     //     : rotr(hist, base) & ~GHR_LEN'(1);
        //     // f_ghr[i] = tmp[i][GHR_LEN:1];

        //     tmp[i] = (i > 0)
        //         ? tmp[i-1] << 1
        //         : rotr(hist, base) & ~GHR_LEN'(1); // clear LSB (write head/base)
        //     f_ghr[i] = tmp[i][GHR_LEN:1];
        // end

        // cannot retire hist bit if leftmost branch in GHR window is unresolved
        // (otherwise, on mispredict of that branch, the current bit will be
        // lost/"shifted out" and unrecoverable)
        okay = rotr(rslv, GHR_LEN-1);

        // for (int i = 0; i < `N; ++i)
        //     rdy[i] = (okay & base_oh_n[i]) ? 1'b1 : 1'b0;
        for (int i = 0; i < `N; ++i)
            rdy[i] = (okay & base_oh_rot[i]) ? 1'b1 : 1'b0;
        for (int i = 1; i < `N; ++i)
            rdy[i] &= rdy[i-1];
        f_rdy_scnt = $countones(rdy);

        // f_rdy_scnt = 0;
        // for (int i = 0; i < `N; ++i) begin
        //     if (!(okay & base_oh_n[i]))
        //         break;
        //     ++f_rdy_scnt;
        // end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            rslv <= '1;
            // hist <= 'hACE1; // heuristic seed to avoid cold start
            hist <= '1;
            base <= DEPTH-1;
            base_oh <= 1 << (DEPTH-1);

        end else if (flush) begin
            rslv[flush_base] <= 1;
            hist[flush_base] <= flush_take;
            base <= flush_base;
            base_oh <= 1 << flush_base;
            /* Do we need to re-set (i.e set high) the bits
            between base and flush_base? c.f. dep table in bman */

        end else begin
            for (int i = 0; i < `NUM_FU_BRU; ++i) begin
                if (!ex_en[i])
                    continue;
                rslv[ex_idx[i]] <= 1;
            end

            for (int i = 0; i < f_en_cnt; ++i) begin
                // rslv <= rslv & ~base_oh_n[i];
                // hist <= f_pred[i]
                //     ? hist | base_oh_n[i]
                //     : hist & ~base_oh_n[i];
                rslv <= rslv & ~base_oh_rot[i];
                hist <= f_pred[i]
                    ? hist | base_oh_rot[i]
                    : hist & ~base_oh_rot[i];
            end
            base <= decr(base, f_en_cnt);
            // base_oh <= base_oh_n[f_en_cnt];
            base_oh <= base_oh_rot[f_en_cnt];
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

// generate
// logic [DEPTH-1:0] tmp;
// assign tmp = rotr(hist, base);
// for (genvar i = 0; i < `N; ++i) begin
//     // assign f_ghr[i] = {tmp[1+i +: GHR_LEN-i], {i{1'b0}}};
//     for (genvar j = 0; j < GHR_LEN; ++j) begin
//         assign f_ghr[i][j] = (j < i)
//             ? 1'b0
//             : tmp[j-i];
//     end

// end
// endgenerate
