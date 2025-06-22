`include "timescale.svh"

module compactor #(
    parameter int REQW=2,
    parameter int GNTW=1,
    type RCNT = `CNT_TYPE(REQW),
    type GCNT = `CNT_TYPE(GNTW)
) (
    input   logic [REQW-1:0]req, // in-order, sparse
    input   GCNT            lim_cnt,

    output  GCNT  [REQW:0]  prefix_cnt,
    output  RCNT            gnt_cnt
        // prefix_cnt[i] "left-compacted index" for the i-th lane.
        // (valid iff req[i])
);
`ifdef SYNTH // ferocious bit twiddling version
    initial begin
        assert(REQW >= GNTW) else $fatal("compactor: reqw (%d) < gntw (%d)", REQW, GNTW);
        assert(REQW >= 2)    else $fatal("compactor: reqw less than 2");
    end

    RCNT [REQW:0] raw_prefix_cnt;
    generate
    assign raw_prefix_cnt[0] = 0;
    assign raw_prefix_cnt[1] = req[0];
    for (genvar i = 2; i <= REQW; ++i) begin
        assign raw_prefix_cnt[i][`CNT_SIZE(i)-1:0] = `UCAST_LEN(raw_prefix_cnt[i-1], i-1) + req[i-1];
    end

    for (genvar i = 2; i < REQW; ++i) begin
        for (genvar j = `CNT_SIZE(i); j < $bits(RCNT); ++j) begin
            assign raw_prefix_cnt[i][j] = 1'b0;
        end
    end
    endgenerate

    generate
    for (genvar i = 0; i <= REQW; ++i) begin
        assign prefix_cnt[i] = (i <= GNTW || raw_prefix_cnt[i] <= GNTW)
            ? raw_prefix_cnt[i]
            : GNTW;
    end
    endgenerate

    logic [REQW-1:0] exceeds;
    generate
    for (genvar i = 0; i < REQW; ++i) begin
        assign exceeds[i] = `UCAST_LEN(raw_prefix_cnt[i+1], i+1) > lim_cnt;
    end
    endgenerate
    always_comb begin
        gnt_cnt = REQW;

        foreach (exceeds[rev]) begin
            if (exceeds[rev])
                gnt_cnt = rev;
        end
    end

`else // faster for simulation
    always_comb begin
        prefix_cnt[0] = 0;
        for (int i = 0; i < REQW; ++i)
            prefix_cnt[i+1] = prefix_cnt[i] + req[i];
    end

    always_comb begin
        RCNT cnt;

        cnt     = 0;
        gnt_cnt = REQW;
        for (int i = 0; i < REQW; ++i) begin
            cnt += req[i];
            if (cnt > lim_cnt && gnt_cnt == REQW)
                gnt_cnt = i;
        end
    end
`endif
endmodule

// module compactor_exp #(
//     parameter int REQW=1,
//     parameter int GNTW=1
// ) (
//     input   logic [REQW-1:0] req, // in-order, sparse
//     input   `CNT_TYPE(GNTW) lim_cnt,

//     output  `CNT_TYPE(REQW) gnt_cnt,
//     output  logic [REQW:0][`CNT_SIZE(GNTW)-1:0] prefix_cnt
//         // prefix_cnt[i] "left-compacted index" for the i-th lane.
//         // (valid iff req[i])
// );
//     localparam SUM_LEVELS = `CNT_SIZE(REQW);
//     logic [SUM_LEVELS-1:0][REQW:0][`CNT_SIZE(REQW)-1:0] sums;
//     generate
//     assign sums[0][0] = 0;
//     for (genvar i = 1; i < REQW+1; ++i) begin
//         assign sums[0][i] = req[i-1];
//     end
//     endgenerate

//     generate
//     for (genvar h = 1; h < SUM_LEVELS; ++h) begin
//         localparam DIST = 1 << (h-1);
//         for (genvar i = 0; i < DIST; ++i) begin
//             assign sums[h][i] = sums[h-1][i];
//         end
//         for (genvar i = DIST; i < REQW+1; ++i) begin
//             assign sums[h][i] = sums[h-1][i] + sums[h-1][i-DIST];
//         end
//     end
//     endgenerate

//     generate
//     for (genvar i = 0; i < REQW+1; ++i) begin
//         assign prefix_cnt[i] = sums[SUM_LEVELS-1][i];
//     end
//     endgenerate

//     generate
//         logic [REQW-1:0] exceeds;
//         logic found;
//         `IDX_TYPE(REQW) first;

//         for (genvar i = 0; i < REQW; ++i) begin
//             assign exceeds[i] = (sums[SUM_LEVELS-1][i] + req[i]) > lim_cnt;
//         end

//         ffs_exp #(
//             .VECW(REQW)
//         ) ff_exceed (
//             .i_vec  (exceeds),
//             .o_vld  (found),
//             .o_idx  (first)
//         );

//         assign gnt_cnt = found ? first : REQW;
//     endgenerate
// endmodule
