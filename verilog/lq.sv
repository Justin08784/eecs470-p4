`include "sys_defs.svh"


module lq #(parameter 
    N=N,
    LSQ_SZ=`LSQ_SZ,
    NUM_FU_STR=NUM_FU_STR,
    NUM_FU_LOD=`LD_BAY_SZ
) (
`ifdef DEBUG
    output DBG_lq dbg,
`endif 
);
    always_comb begin
`ifdef DEBUG
        dbg          = '0;
`endif
    end
endmodule
