`include "timescale.svh"

module ffs #(
    parameter int VECW=2
) (
    input   logic [VECW-1:0] i_vec,
    output  logic o_vld,
    output  `IDX_TYPE(VECW) o_idx
);
    always_comb begin
        o_vld = |i_vec;
        o_idx = 0;

        // TRICKY: iterate highest -> lowest index. Find lowest set index, if any.
        // (This improves timing compared to having an explicit `break;`.
        // See uftb/btb way-searching in locate for other applications)
        foreach (i_vec[rev]) begin
            if (i_vec[rev])
                o_idx = rev; // last/lowest qualifying assignment wins
        end
    end
endmodule

// find first set index
// module ffs_exp #(
//     parameter int VECW  =N
// ) (
//     input   logic [VECW-1:0] i_vec,
//     output  logic o_vld,
//     output  `IDX_TYPE(VECW) o_idx
// );
//     localparam LEVELS = `CNT_SIZE(VECW);
//     logic [LEVELS-1:0][VECW-1:0] lset;

//     generate
//     assign lset[0] = i_vec << 1;
//     for (genvar h = 1; h < LEVELS; ++h) begin
//         localparam DIST = 1 << (h-1);
//         assign lset[h] = lset[h-1] | (lset[h-1] << DIST);
//     end
//     endgenerate

//     logic [VECW-1:0] onehot;
//     assign onehot = i_vec & ~lset[LEVELS-1];
//     assign o_vld = |i_vec;
//     always_comb begin
//         o_idx = '0;
//         for (int i = 0; i < VECW; ++i) begin
//             if (onehot[i]) begin
//                 o_idx = i; 
//             end
//         end
//     end

// endmodule
