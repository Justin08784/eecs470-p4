`include "sys_defs.svh"
`include "dcache_block_direct.svh"


module sq #(parameter 
    N=N,
    LSQ_SZ=`LSQ_SZ,
    NUM_FU_STR=NUM_FU_STR,
    NUM_FU_LOD=NUM_FU_LOD,
    LD_BAY_SZ=`LD_BAY_SZ
) (
`ifdef DEBUG
    output DBG_sq dbg,
`endif 
);

    always_comb begin
`ifdef DEBUG
        dbg             = '0;
`endif
    end

endmodule
