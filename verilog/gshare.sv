
`include "sys_defs.svh"

// // meta-chooser for 2 predictors
// module chooser #(
//     parameter GHR_LEN   = GHR_LEN,
//     parameter N         = N
// ) (
//     input   clock,
//     input   reset,

//     // puq updates
//     input   puq2fetch       i_upd,

//     // fetch
//     input   WADDR [N-1:0]   i_qry, // branch pc
//     output  logic [N-1:0]   o_sel
// );
//     localparam TBL_SZ = 1 << GHR_LEN;
//     logic [TBL_SZ-1:0][1:0] choice;

//     generate
//     for (genvar i = 0; i < N; ++i) begin
//         // 0 -> bim. 1 -> gshare
//         assign o_sel[i] = query_sc(choice[i_qry[i][GHR_LEN-1:0]]);
//     end
//     endgenerate

//     logic corr_bim, corr_gshare, dir, delta;
//     always_comb begin
//         corr_bim    = i_upd.dat.pred_bim    == i_upd.dat.take;
//         corr_gshare = i_upd.dat.pred_gshare == i_upd.dat.take;

//         dir     = corr_gshare;
//         delta   = corr_bim != corr_gshare;
//     end

//     always_ff @(posedge clock) begin
//         if (reset)
//             for (int i = 0; i < TBL_SZ; ++i)
//                 choice[i] <= 2'b01; // weakly favor bim (bim converges faster to new branches)
//         else if (i_upd.en && i_upd.dat.cond) begin // train only on conditional branches!
//             if (delta) begin
//                 choice[i_upd.dat.pc[GHR_LEN-1:0]] <=
//                     update_sc(choice[i_upd.dat.pc[GHR_LEN-1:0]], dir);
//             end
//         end
//     end
// endmodule

// // 2-bit sc bimodal table
// module bim #(
//     parameter GHR_LEN   = GHR_LEN,
//     parameter N         = N
// ) (
//     input   clock,
//     input   reset,

//     // puq updates
//     input   puq2fetch       i_upd,

//     // fetch
//     input   WADDR [N-1:0]   i_qry, // branch pc
//     output  logic [N-1:0]   o_pred
// );
//     localparam PHT_SZ = 1 << GHR_LEN;
//     logic [PHT_SZ-1:0][1:0] pht;

//     generate
//     for (genvar i = 0; i < N; ++i) begin
//         assign o_pred[i] = query_sc(pht[i_qry[i][GHR_LEN-1:0]]);
//     end
//     endgenerate

//     always_ff @(posedge clock) begin
//         if (reset)
//             for (int i = 0; i < PHT_SZ; ++i)
//                 pht[i] <= 2'b01;
//         else if (i_upd.en && i_upd.dat.cond) // train only on conditional branches!
//             pht[i_upd.dat.pc[GHR_LEN-1:0]] <=
//                 update_sc(pht[i_upd.dat.pc[GHR_LEN-1:0]], i_upd.dat.take);
//     end
// endmodule

module gshare (
    input   clock,
    input   reset,

    // puq updates
    input   logic       i_uen,
    input   logic [FH_LEN-1:0] i_uhash,
    input   BPU_UPD_PKT i_udat,

    // fetch
    input   logic [FH_LEN-1:0] i_hash,
    output  logic [NUM_BR_SLOTS-1:0] o_pred
);
    localparam PHT_SZ = 1 << FH_LEN;
`ifdef DEBUG
    logic [PHT_SZ-1:0][1:0] touched;
`endif
    // logic [1:0] pht [PHT_SZ-1:0]; // ram inference?
    logic [PHT_SZ-1:0][3:0] pht;
    logic [3:0] rrec;
    logic [3:0] urec; // read, update records

    // assign i_hash = i_ghr ^ i_qry[GHR_LEN-1:0];
    assign rrec = pht[i_hash];
    assign o_pred[0] = query_sc(rrec[1:0]);
    assign o_pred[1] = query_sc(rrec[3:2]);

    assign urec = pht[i_uhash];

    always_ff @(posedge clock) begin
        if (reset) begin
            touched <= '0;
            for (int i = 0; i < PHT_SZ; ++i)
                pht[i] <= {WN, WN};
        end else if (i_uen && i_udat.en_dir_update && i_udat.md.cond) begin // train only on conditional branches!
            touched[i_uhash][i_udat.slot_idx] <= '1;
            if (i_udat.slot_idx)
                pht[i_uhash][3:2] <= update_sc(urec[3:2], i_udat.take);
                // pht[i_uhash][3:2] <= update_sc(pht[i_uhash][3:2], i_udat.take);
            else
                pht[i_uhash][1:0] <= update_sc(urec[1:0], i_udat.take);
                // pht[i_uhash][1:0] <= update_sc(pht[i_uhash][1:0], i_udat.take);
            // pht[i_uhash][1:0] <= i_udat.slot_idx ? urec[1:0] : update_sc(urec[1:0], i_udat.take);
            // pht[i_uhash][3:2] <= i_udat.slot_idx ? update_sc(urec[3:2], i_udat.take) : urec[3:2];
        end
    end

    task print_gshare;
        $display(">> gshare");
        if (i_uen && i_udat.en_dir_update && i_udat.md.cond)
            $display("i_uhash: %b, take: %b, slot_idx: %b, urec: [%b, %b]",
                i_uhash,
                i_udat.take,
                i_udat.slot_idx,
                urec[1:0],
                urec[3:2]
            );
        else
            $display("N/A!");

        for (int i = 0; i < PHT_SZ; ++i) begin
            if (|touched[i])
                $display("pht[%6b]: (%b, %b)",
                    i,
                    touched[i][0] ? pht[i][1:0] : 2'bxx,
                    touched[i][1] ? pht[i][3:2] : 2'bxx
                );
        end
    //     $display("i_ghr: %b, i_qry: %x, i_hash: %b, o_pred: [%b, %b]",
    //         i_ghr,
    //         i_qry,
    //         i_hash,
    //         o_pred[0],
    //         o_pred[1]
    //     );
        $display("upd: {en: %b, base: %d, take: %b, i_uhash: %b, slot_idx: %b}", i_uen, i_udat.base, i_udat.take, i_uhash, i_udat.slot_idx);
        $display("<< gshare");
    endtask

endmodule