Terminology:
- vld, rdy
- vld=valid. Sender side: is the sender requesting to send data on a line?
- rdy=ready. Receiver side: is the receiver ready/requesting to receive data on a line?

Notes:
- When making a change, make sure to edit dependents (to/from) as well!


/* 
================================================
Reservation Station (RS)
================================================
*/
module rs (
input clock, reset, flush,

// dispatch
output  logic       [$clog2(N):0] rs_scnt,
    // [TODO: delete]
    // - To: dispatcher
input   logic       [N-1:0] d_vld,
    // [TODO: delete]
    // - From: dispatcher
input   ID_RESULT   [N-1:0] d_dat,
    // [TODO: delete]
    // - From: dispatcher
output  ID_RESULT   [RS_SZ-1:0] rs_rdy,
    // [TODO: delete]
    // - To: dispatcher
    // - rs_rdy[i] = !rs_table[i].busy

output  logic       [DIS_MAX-1:0] d_vld,
    // [TODO: impl]
    // - From: dispatcher
    // - Need new sys_defs.svh constant DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
output  logic       [DIS_MAX-1:0][RS_SZ-1:0] d_dat2rs,
    // [TODO: impl]
    // - From: dispatcher
    // - asg = assignment
    // - If (d_vld[i] && d_dat2rs[i][j]), d_dat[i] should go to rs_table[j]
input   ID_RESULT   [DIS_MAX-1:0] d_dat,
    // [TODO: impl]
    // - From: dispatcher

// issue
// for X in {FU types}:
input   logic       [NUM_FU_X-1:0]    fu_rdy_X,
    // - From EX
output  logic       [NUM_FU_X-1:0]    fu_vld_X,
    // - To EX
output  ID_RESULT   [NUM_FU_X-1:0]    fu_dat_X,
    // - To EX

// complete (CDB)
input   logic           [N-1:0] c_en,
    // - From EX
input   PHYS_REG_IDX    [N-1:0] c_ts
    // - From EX
);
endmodule


/* 
================================================
Dispatcher
================================================
*/
module dispatch (
input clock, reset, flush,
);
endmodule