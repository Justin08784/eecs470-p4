`include "sys_defs.svh"


module lq #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
    NUM_FU_STORE=`NUM_FU_STORE,
    NUM_FU_LOAD=`LD_BAY_SZ
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
