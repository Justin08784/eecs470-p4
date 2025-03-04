Terminology:
- vld, rdy
- vld=valid. Sender side: is the sender requesting to send data on a line?
- rdy=ready. Receiver side: is the receiver ready/requesting to receive data on a line?
- There is some confusion with en, vld, rdy.
There needs to be a clearer distinction between vld (as in request send) and rdy 
(as in request receive), vs. en (which is ORDER send, having accounted for both
vld and rdy already). In short, en is a "forced" signal which doesn't need confirmation
or negotiation from anywhere else.

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
output  logic       [$clog2(N):0] rs_scnt, // TODO: rename to rs_rdy_scnt
    // - To: dispatcher
input   ID_RESULT   [N-1:0] d_dat,
    // - From: dispatcher
// >> [TODO: delete]
input   logic       [N-1:0] d_vld,
    // - From: dispatcher
    // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    //   i.e. forall i < j, if d_vld[i] && d_vld[j], 
    //   then d_dat[i] <_{Prog Order} d_dat[j]
// << [TODO: delete]

// >> [TODO: impl]
input   logic       [$clog2(N):0] d_en_cnt,
    // - From: dispatcher
    // - Number of enabled dispatch lines? (replacement for d_vld)
    // - Question: permit
    // 1) only N dispatches, OR
    // 2) a different limit number of dispatches DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
    // (DIS_MAX will be a new sys_defs.svh constant) ?
// << [TODO: impl]

// >> UNSURE
output  ID_RESULT   [RS_SZ-1:0] rs_rdy,
    // - To: dispatcher
    // - rs_rdy[i] = !rs_table[i].busy
input   logic       [N-1:0][RS_SZ-1:0] d_dat2rs,
    // - From: dispatcher
    // - asg = assignment
    // - If (d_vld[i] && d_dat2rs[i][j]), d_dat[i] should go to rs_table[j]
// << UNSURE

// issue
// for X in {FU types}:
input   logic       [NUM_FU_X-1:0]    fu_rdy_X,
    // - From EX
output  logic       [NUM_FU_X-1:0]    fu_vld_X, // TODO: rename to fu_en_X
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
Re-order Buffer (ROB)
================================================
*/
module rob (
input                           clock, reset,

// >> [TODO: delete]
input  [1:0]                    dispatch_en,
input  [1:0]                    retire_en,
input                           err,
input  [1:0][WIDTH-1:0]         next_insn,
output logic [1:0]              wr_valid,
    // We don't need this anymore because dispatcher only dispatches as
    // many as ROB can accept.
output logic [1:0]              rd_valid,
    // See above.
output logic [1:0][WIDTH-1:0]   completed_insn,
output logic [CNT_BITS:0]       free_spots,
output logic                    full
// << [TODO: delete]


// >> [TODO: impl]

// dispatch (write)
output logic    [$clog2(N):0]   rob_rdy_scnt,
    // To: dispatcher
    // saturating counter for number of free rob entries
output logic                    full,
    // To: dispatcher

input   [$clog2(N):0]           d_en_cnt,
    // From: dispatcher
    // - Number of valid dispatch lines?
input   ROB_ENTRY   [N-1:0]     d_dat,
    // From: dispatcher
    // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!

// complete (write)
input   logic        [N-1:0]    c_en,
    // - From EX
input   PHYS_REG_IDX [N-1:0]    c_ts,
    // - From EX

// retire (read)
output logic [N-1:0]            r_en,
    // To: idk
output struct packed {
    PHYS_REG_IDX tag;
    PHYS_REG_IDX t_old;
} [N-1:0] r_dat,
    // To: idk
// << [TODO: impl]


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