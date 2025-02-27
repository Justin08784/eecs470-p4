Terminology:
* vld, rdy
* vld=valid. Sender side: is the sender requesting to send data on a line?
* rdy=ready. Receiver side: is the receiver ready/requesting to receive data on a line?
* X = pending deletion
* ? = pending implementation

Notes:
* When making a change, make sure to edit dependents (to/from) as well!

# Reservation Station (RS):
* input clock, reset, flush

## dispatch
* X output  logic       [$clog2(N):0] rs_scnt,
    * To: dispatcher
* X input   logic       [N-1:0] d_vld,
    * From: dispatcher
* X input   ID_RESULT   [N-1:0] d_dat,
    * From: dispatcher
* ? output  ID_RESULT   [RS_SZ-1:0] rs_rdy,
    * To: dispatcher
    * rs_rdy[i] = !rs_table[i].busy
* ? output  logic       [DIS_MAX-1:0] d_vld,
    * From: dispatcher
    * Need new sys_defs.svh constant DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
* ? output  logic       [DIS_MAX-1:0][RS_SZ-1:0] d_dat2rs,
    * From: dispatcher
    * asg = assignment
    * If (d_vld[i] && d_dat2rs[i][j]), d_dat[i] should go to rs_table[j]
* ? input   ID_RESULT   [DIS_MAX-1:0] d_dat,
    * From: dispatcher

## issue
for X in {FU types}:
* input   logic       [NUM_FU_X-1:0]    fu_rdy_X,
    * From EX
* output  logic       [NUM_FU_X-1:0]    fu_vld_X,
    * To EX
* output  ID_RESULT   [NUM_FU_X-1:0]    fu_dat_X,
    * To EX

## complete (CDB)
* input   logic   [N-1:0] c_en,
    * From EX
* input   PHYS_REG_IDX[N-1:0] c_ts
    * From EX
