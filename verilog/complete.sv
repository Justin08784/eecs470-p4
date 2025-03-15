`include "sys_defs.svh"


module compelte #(parameter 
N = `N
) (
    input clock,
    input reset,
    input flush,

    input logic [N-1:0] c_en,
    input PHYS_REG_IDX [N-1:0] c_ts,
    input DATA [N-1:0] c_res
);


endmodule