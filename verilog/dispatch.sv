`include "sys_defs.svh"


module dispatch (
    input clock,
    input reset,
    input [$clog(RS_SZ):0] rs_free,
    input [$clog(ROB_SZ):0] rob_free,
    output [31:0] insts [N:0],
    output [N:0] inst_valid
);



endmodule