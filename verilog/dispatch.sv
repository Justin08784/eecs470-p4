`include "sys_defs.svh"

// `define fetch_cnt 19

module dispatch (
    input clock,
    input reset,
    input [$clog(RS_SZ):0] rs_free,
    input [$clog(ROB_SZ):0] rob_free,
    output [$clog(`N):0] dispatch_cnt, //tells stage_if how many insts to dispatch
    output dispatch_vld //will be used to set if_valid to false if cnt == 0
);

// logic next_cnt;
logic next_vld;

// I think we actually just want this in an always_comb
// and not clock dependent bc if it is clock dependent
// the net output would end up being a cycle behind
always_comb begin
    assign dispatch_cnt = (rs_free <= rob_free) ? rs_free : rob_free;
    assign dispatch_vld = dispatch_cnt > 0;
end



// always_ff(@posedge clock) begin
//     if (reset) begin
//         dispatch_cnt <= 0;
//         dispatch_vld <= 0;
//     end
//     else begin
//         dispatch_cnt <= next_cnt;
//         dispatch_vld <= next_vld;
//     end
// end

endmodule