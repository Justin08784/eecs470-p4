
`include "sys_defs.svh"

// meta-chooser for 2 predictors
module chooser #(
    parameter GHR_LEN   = GHR_LEN,
    parameter N         = N
) (
    input   clock,
    input   reset,

    // puq updates
    input   puq2fetch       i_upd,

    // fetch
    input   WADDR [N-1:0]   i_qry, // branch pc
    output  logic [N-1:0]   o_sel
);
    localparam TBL_SZ = 1 << GHR_LEN;
    logic [TBL_SZ-1:0][1:0] choice;

    generate
    for (genvar i = 0; i < N; ++i) begin
        // 0 -> bim. 1 -> gshare
        assign o_sel[i] = query_sc(choice[i_qry[i][GHR_LEN-1:0]]);
    end
    endgenerate

    logic corr_bim, corr_gshare, dir, delta;
    always_comb begin
        corr_bim    = i_upd.dat.pred_bim    == i_upd.dat.take;
        corr_gshare = i_upd.dat.pred_gshare == i_upd.dat.take;

        dir     = corr_gshare;
        delta   = corr_bim != corr_gshare;
    end

    always_ff @(posedge clock) begin
        if (reset)
            for (int i = 0; i < TBL_SZ; ++i)
                choice[i] <= 2'b01; // weakly favor bim (bim converges faster to new branches)
        else if (i_upd.en && i_upd.dat.cond) begin // train only on conditional branches!
            if (delta) begin
                choice[i_upd.dat.pc[GHR_LEN-1:0]] <=
                    update_sc(choice[i_upd.dat.pc[GHR_LEN-1:0]], dir);
            end
        end
    end
endmodule

// 2-bit sc bimodal table
module bim #(
    parameter GHR_LEN   = GHR_LEN,
    parameter N         = N
) (
    input   clock,
    input   reset,

    // puq updates
    input   puq2fetch       i_upd,

    // fetch
    input   WADDR [N-1:0]   i_qry, // branch pc
    output  logic [N-1:0]   o_pred
);
    localparam PHT_SZ = 1 << GHR_LEN;
    logic [PHT_SZ-1:0][1:0] pht;

    generate
    for (genvar i = 0; i < N; ++i) begin
        assign o_pred[i] = query_sc(pht[i_qry[i][GHR_LEN-1:0]]);
    end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset)
            for (int i = 0; i < PHT_SZ; ++i)
                pht[i] <= 2'b01;
        else if (i_upd.en && i_upd.dat.cond) // train only on conditional branches!
            pht[i_upd.dat.pc[GHR_LEN-1:0]] <=
                update_sc(pht[i_upd.dat.pc[GHR_LEN-1:0]], i_upd.dat.take);
    end
endmodule

module gshare #(
    parameter GHR_LEN   = GHR_LEN,
    parameter N         = N
) (
    input   clock,
    input   reset,

    // puq updates
    input   puq2fetch i_upd,

    // fetch
    input   logic [N-1:0][GHR_LEN-1:0]  i_ghr,
    input   WADDR [N-1:0]               i_qry, // branch pc
    output  logic [N-1:0][GHR_LEN-1:0]  o_hash,
    output  logic [N-1:0]               o_pred
);
    localparam PHT_SZ = 1 << GHR_LEN;
    // logic [1:0] pht [PHT_SZ-1:0]; // ram inference?
    logic [PHT_SZ-1:0][1:0] pht;

    generate
    for (genvar i = 0; i < N; ++i) begin
        assign o_hash[i] = i_ghr[i] ^ i_qry[i][GHR_LEN-1:0];
        assign o_pred[i] = query_sc(pht[o_hash[i]]);
    end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset)
            for (int i = 0; i < PHT_SZ; ++i)
                pht[i] <= 2'b01;
        else if (i_upd.en && i_upd.dat.cond) // train only on conditional branches!
            pht[i_upd.dat.hash] <= update_sc(pht[i_upd.dat.hash], i_upd.dat.take);
    end

    task print_gshare;
        $display(">> gshare");
        $display("i_ghr: [%b, %b], i_qry: [%x, %x], o_hash: [%b, %b], o_pred: [%b, %b]",
            i_ghr[0],
            i_ghr[1],
            i_qry[0],
            i_qry[1],
            o_hash[0],
            o_hash[1],
            o_pred[0],
            o_pred[1]
        );
        $display("upd: {en: %b, hash: %b, take: %b}", i_upd.en, i_upd.dat.hash, i_upd.dat.take);
        $display("<< gshare");
    endtask

endmodule