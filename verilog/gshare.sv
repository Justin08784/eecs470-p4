
`include "sys_defs.svh"

module gshare #(
    parameter GHR_LEN   = GHR_LEN,
    parameter N         = `N
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
    logic [1:0][PHT_SZ-1:0] pht;

    function automatic logic [1:0] update_sc(
        input logic unsigned [1:0] sc,
        input logic take
    );
        if (take)
            return sc == 2'b11 ? 2'b11 : sc + 1;
        else
            return sc == 0 ? 0 : sc - 1;
    endfunction

    function automatic logic query_sc(input logic [1:0] sc);
        return sc[1];
    endfunction

    generate
    for (genvar i = 0; i < N; ++i) begin
        assign o_hash[i] = i_ghr[i] ^ i_qry[i][GHR_LEN-1:0];
        assign o_pred[i] = query_sc(pht[o_hash[i]]);
    end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset)
            for (int i = 0; i < PHT_SZ; ++i)
                pht[i] <= '0;
        else if (i_upd.en)
            pht[i_upd.dat.hash] <= update_sc(pht[i_upd.dat.hash], i_upd.dat.take);
    end

endmodule