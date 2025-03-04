Terminology:
- `*_vld` = valid signal (sender requests send)
- `*_rdy` = ready signal (receiver requests receive)
- `*_en`  = enable signal (send/execution must happen, no further confirmation/negotiation needed)
e.g. When A wants to send data to B:
1. A requests vld
2. B requests rdy (input to A)
3. A orders `en = vld & rdy` (input to B)
(usually, a transmission is sender-coordinated)

- `*_scnt`= saturating counter

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
        // - To: dispatch
    input   ID_RESULT   [N-1:0] d_dat,
        // - From: dispatch
    // >> [TODO: delete]
    input   logic       [N-1:0] d_vld,
        // - From: dispatch
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
        //   i.e. forall i < j, if d_vld[i] && d_vld[j], 
        //   then d_dat[i] <_{Prog Order} d_dat[j]
    // << [TODO: delete]

    // >> [TODO: impl]
    input   logic       [$clog2(N):0] d_en_cnt,
        // - From: dispatch
        // - Number of enabled dispatch lines? (replacement for d_vld)
        // - Question: permit
        // 1) only N dispatches, OR
        // 2) a different limit number of dispatches DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
        // (DIS_MAX will be a new sys_defs.svh constant) ?
    // << [TODO: impl]

    // >> UNSURE
    output  ID_RESULT   [RS_SZ-1:0] rs_rdy,
        // - To: dispatch
        // - rs_rdy[i] = !rs_table[i].busy
    input   logic       [N-1:0][RS_SZ-1:0] d_dat2rs,
        // - From: dispatch
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
        // We don't need this anymore because dispatch only dispatches as
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
        // To: dispatch
        // saturating counter for number of free rob entries
    output logic                    full,
        // To: dispatch

    input   [$clog2(N):0]           d_en_cnt,
        // From: dispatch
        // - Number of valid dispatch lines?
    input   ROB_ENTRY   [N-1:0]     d_dat,
        // From: dispatch
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
Complete list
================================================
*/
// internal states maps PHYS_REG_IDX -> is_complete
// TODO: Decide between Version 1 and 2:
// 1) rat's nest of wires; less efficient?
// 2) cleaner wiring; more efficient?; coherence between replicated cpl_lst's
module complete_list (
    // >> [TODO: impl] :: VERSION 1 (centralized r/w)
    input clock, reset, flush,

    // retire (read)
        // To/from: ROB
    input logic         [N-1:0] r_en,
    input PHYS_REG_IDX  [N-1:0] r_ts,
    output logic        [N-1:0] r_cpls,

    // complete (write)
        // From: EX
    input logic         [N-1:0] c_en,
    input PHYS_REG_IDX  [N-1:0] c_ts,

    // issue (read)
        // To/from: RS
    input logic         [RS_SZ-1:0] s_en,
    input PHYS_REG_IDX  [RS_SZ-1:0] s_t1s,
    input PHYS_REG_IDX  [RS_SZ-1:0] s_t2s,
    output logic        [RS_SZ-1:0] s_cpl1s,
    output logic        [RS_SZ-1:0] s_cpl2s,

    // dispatch (read and write)
        // To/from: dispatch
    input logic         [RS_SZ-1:0] d_en,
    input PHYS_REG_IDX  [RS_SZ-1:0] d_ts,
    input PHYS_REG_IDX  [RS_SZ-1:0] d_t1s,
    input PHYS_REG_IDX  [RS_SZ-1:0] d_t2s,
    output logic        [RS_SZ-1:0] d_cpl1s,
    output logic        [RS_SZ-1:0] d_cpl2s
    // << [TODO: impl]

    // >> [TODO: impl] :: VERSION 2 (centralized writes, distributed reads)
    input clock, reset, flush,

    // complete (write)
    input logic         [N-1:0] c_en,
    input PHYS_REG_IDX  [N-1:0] c_ts,
        // From: EX

    output logic        [PHYS_REG_SZ_R10K] c_cpl_lst
        // To: RS (issue)
        // - complete list state after sets by completes

    // dispatch (read and write)
    input logic         [RS_SZ-1:0] d_en,
    input PHYS_REG_IDX  [RS_SZ-1:0] d_ts,
        // From: dispatch

    output logic        [PHYS_REG_SZ_R10K] d_cpl_lst
        // To: dispatch
        // - complete list state after: 
        //   1) sets by completes, AND 
        //   2) clears by renames/dispatches

    // Question: can we combine writes by complete and renames into
    // a single step, or do we need the intermediate c_cpl_lst?
    // << [TODO: impl]
);
endmodule

/* 
================================================
Dispatch
================================================
*/
module dispatch (
    input clock, reset, flush,
);
endmodule

/* 
================================================
Map Table
================================================
*/
// Comments:
// - should be declared as a submodule of dispatch eh? doesnt seem anyone
// else references it...?
// - map table is more complicated than a simple lookup. forall i < j,
// src1s[j], src2s[j] may potentially be dsts[i]. i.e. there is a serial dependency
module map_table (
    input clock, reset,
    // retire ??
    // complete ??
    // issue ??

    // dispatch
    input logic         [$clog2(N):0] d_en_cnt,
        // - Number of valid dispatch lines?
    input REG_IDX       [N-1:0] d_src1s,
    input REG_IDX       [N-1:0] d_src2s,
    input REG_IDX       [N-1:0] d_dsts,
        // From: dispatch
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!

    output PHYS_REG_IDX [N-1:0] t1s,
        // To: dispatch
        // - Renamed physical registers tags for src1s
        // - src1[i] -> t1[i]
    output PHYS_REG_IDX [N-1:0] t2s
        // To: dispatch
        // - Renamed physical registers tags for src2s
        // - src2[i] -> t2[i]
);
endmodule

/* 
================================================
Architectural Map
================================================
*/
module arch_map (
    input clock, reset,
    // retire
    // complete
    // issue
    // dispatch
);
endmodule

/* 
================================================
(physical) Register File
================================================
*/
module prf (
    input clock, reset, flush,
    // retire
    // complete
    // issue
    // dispatch
);
endmodule
