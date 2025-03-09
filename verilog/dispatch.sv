`include "sys_defs.svh"


module dispatch (
    input clock,
    input reset,

    //counts of how many free entries in rs, rob, lsq, and free list
    input [$clog(`RS_SZ):0] rs_free,
    input [$clog(`ROB_SZ):0] rob_free,
    input [$clog(`LSQ_SZ):0] lsq_free,
    input [$clog(`PHYS_REG_SZ_R10K):0] flist_free,


    //tells stage_if/id how many insts to dispatch,
    //as well as teh free list how many tags to issue
    output [$clog(`N):0] dispatch_cnt, 

);

int max = 2;
// logic [$bits(`RS_ENTRY)-1:0] next_rs [RS_SZ-1:0];


always_comb begin
    
    //logic to find the minimum # of spots free across the 4 inputs
    int min1 = (rs_free < rob_free) ? rs_free : rob_free;
    int min2 = (lsq_free < flist_free) ? lsq_free : flist_free;
    dispatch_cnt = (min1 < min2) ? min1 : min2;
    dispatch_cnt = (dispatch_cnt > `N) ? `N : dispatch_cnt;
    
end


endmodule


