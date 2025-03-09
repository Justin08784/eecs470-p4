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
Fetch
================================================
*/
module fetch(
    input clock,          // system clock
    input reset,          // system reset

    input               [N-1:0] if_valid,       // only go to next PC when true
    input               [N-1:0] take_branch,    // taken-branch signal
    input ADDR          [N-1:0] branch_target,  // target pc: use if take_branch is TRUE
    input MEM_BLOCK     [N-1:0] Imem_data,      // data coming back from Instruction memory

    // tags from memory
    input MEM_TAG       [N-1:0] Imem2proc_transaction_tag, // Should be zero unless there is a response
    input MEM_TAG       [N-1:0] Imem2proc_data_tag,

    output MEM_COMMAND  [N-1:0] Imem_command, // Command sent to memory
    output IF_ID_PACKET [N-1:0] if_packet,
    output ADDR         [N-1:0] Imem_addr // address sent to Instruction memory
);
endmodule

/* 
================================================
Decode
================================================
*/
module decode(
    input clock,           // system clock
    input reset,           // system reset

    input IF_ID_PACKET  [N-1:0] if_id_reg,
    input               [N-1:0] wb_regfile_en,   // Reg write enable from WB Stage
    input REG_IDX       [N-1:0] wb_regfile_idx,  // Reg write index from WB Stage
    input DATA          [N-1:0] wb_regfile_data, // Reg write data from WB Stage

    output ID_EX_PACKET [N-1:0] id_packet
);
endmodule

/* 
================================================
Execute / Functional units
================================================
*/
module execute(
    input ID_EX_PACKET   [N-1:0] id_ex_reg,

    output EX_MEM_PACKET [N-1:0] ex_packet
);
endmodule

/* 
================================================
Reservation Station (RS)
================================================
*/
module rs #(parameter 
    N=`N,
    RS_SZ=`RS_SZ,
    FU_IDX_NUM=`FU_IDX_NUM,
    NUM_FU_ALU=`NUM_FU_ALU,
    NUM_FU_MULT=`NUM_FU_MULT,
    NUM_FU_LOAD=`NUM_FU_LOAD,
    NUM_FU_STORE=`NUM_FU_STORE
) (
    input clock, reset, flush,

    // dispatch
    output  logic       [$clog2(N):0] rs_scnt, // TODO: rename to rs_rdy_scnt
        // To: dispatch
    input   ID_RESULT   [N-1:0] d_dat,
        // - From: dispatch
    input   logic       [$clog2(N):0] d_en_cnt,
        // - From: dispatch
        // - Number of enabled dispatch lines? (replacement for d_vld)
        // - Question: permit
        // 1) only N dispatches, OR
        // 2) a different limit number of dispatches DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
        // (DIS_MAX will be a new sys_defs.svh constant) ?

    // >> UNSURE
    output  ID_RESULT   [RS_SZ-1:0] rs_rdy,
        // To: dispatch
        // - rs_rdy[i] = !rs_table[i].busy
    input   logic       [N-1:0][RS_SZ-1:0] d_dat2rs,
        // - From: dispatch
        // - asg = assignment
        // - If (d_vld[i] && d_dat2rs[i][j]), d_dat[i] should go to rs_table[j]
        // - I'm unsure about this because it seems better to let RS handle dat->entry
        //   assignment internally, instead of unnaturally offloading it to the dispatcher.
        // - TODO: ...speaking of which, we should let a submodule handle dat2rs assignment
    // << UNSURE

    // issue
    // for X in {FU types}:
    input   logic       [NUM_FU_X-1:0]    fu_rdy_X,
        // - From: EX
    output  logic       [NUM_FU_X-1:0]    fu_vld_X, // TODO: rename to fu_en_X
        // To: EX
    output  ID_RESULT   [NUM_FU_X-1:0]    fu_dat_X,
        // To: EX
        // - TODO: ...we should let a submodule handle issuing logic

    // complete (CDB)
    input   logic           [N-1:0] c_en,
        // - From: EX
    input   PHYS_REG_IDX    [N-1:0] c_ts
        // - From: EX
    );
endmodule

/* 
================================================
Re-order Buffer (ROB)
================================================
*/
module rob #(
    parameter ROB_SZ = `ROB_SZ,  // num elements
    parameter N=`N
) (
    `ifdef DEBUG
    output  ROB_ENTRY   [ROB_SZ-1:0]    state_dbg,
    `endif 
    input                       clock, reset,

    // retire (read)
    output struct packed {
        logic [$clog2(N):0]     r_en_cnt;

        PHYS_REG_IDX [N-1:0]    tag;
        PHYS_REG_IDX [N-1:0]    t_old;
    } r_out,

    // complete (write)
    input struct packed {
        logic [N-1:0]           c_en;
            // - From: EX
        ROB_IDX [N-1:0]         c_rob_idxs;
            // - From: EX
    } c_in,

    // dispatch (write)
    output struct packed {
        logic [$clog2(N):0]     rob_rdy_scnt;
            // To: dispatch
            // saturating counter for number of free rob entries
        ROB_IDX [N-1:0]         rob_idxs;
            // To: dispatch
            // rob idxs of entries that can be allocated this cycle
            // Option 1: This
            // Option 2: expose HEAD pointer and let dispatcher generate these
            // (main concern with option 2 is it could be wrong? idk)
    } d_out,
    input struct packed {
        logic [$clog2(N):0]     d_en_cnt;
            // From: dispatch
            // - Number of enabled dispatch lines?
        logic [N-1:0][$clog2(`PHYS_REG_SZ_R10K)-1:0] tag;
        logic [N-1:0][$clog2(`PHYS_REG_SZ_R10K)-1:0] t_old;
            // From: dispatch
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } d_in
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
// Comments: I don't like the idea of a complete list anymore. It's a centralized bottleneck.
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
        // - Question: Exposing the cpl_lst directly to RS gives me some concerns.
        //   So if potentially any RS can ready + issue via indexing into cpl_lst
        //   (e.g. c_cpl_lst[t1]), and if there are 16 RS  entries, does this mean 
        //   16 * 2 implicit read ports? Isn't this like... bad?

    // dispatch (read and write)
    input logic         [RS_SZ-1:0] d_en,
    input PHYS_REG_IDX  [RS_SZ-1:0] d_ts,
        // From: dispatch

    output logic        [PHYS_REG_SZ_R10K] d_cpl_lst
        // To: dispatch
        // - complete list state after: 
        //   1) sets by completes, AND 
        //   2) clears by renames/dispatches
        // - Same implicit read port concert as for c_cpl_lst.

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
    // TODO: wrap module specific ins and outs into anonymous structs
    // e.g. input struct packed { ... } rob_in;


    // RS
    input logic       [$clog2(N):0] rs_scnt, // TODO: rename to rs_rdy_scnt
        // - From: RS
    output ID_RESULT   [N-1:0] d_dat,
        // - To: RS

    output logic       [$clog2(N):0] d_en_cnt,
        // - To: RS
        // - Number of enabled dispatch lines? (replacement for d_vld)
        // - Question: permit
        // 1) only N dispatches, OR
        // 2) a different limit number of dispatches DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
        // (DIS_MAX will be a new sys_defs.svh constant) ?


    // ROB
    input logic    [$clog2(N):0]    rob_rdy_scnt,
        // From: ROB
        // saturating counter for number of free rob entries
    output [$clog2(N):0]            d_en_cnt,
        // To: ROB
        // - Number of enabled dispatch lines?
    output ROB_ENTRY   [N-1:0]      d_dat,
        // To: ROB
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!


    // Free list
    input logic    [$clog2(N):0]    free_rdy_scnt,
        // From: Free list
        // - sat. count of number of free pregs in free list;
        //   count reflects any pregs returned in retire! (i.e. AFTER retires)
    output logic     [$clog2(N):0]  d_en_cnt,
        // To: Free list
        // - number of enabled dispatch lines WHO NEED A DEST PREG 
        //   (e.g. no stores)
        //   (i.e. may only be a strict subset of dispatching insns!)
    output PHYS_REG_IDX [N-1:0]     d_ts,
        // From: Free list
        // - newly allocated pregs


    // Map table
    output logic         [$clog2(N):0] en_cnt,
        // - Number of enabled dispatch lines?
        // - NOTE: For in-order stuff with serial deps (like dispatch), use c(ou)nts;
        // otherwise use en(able) buses.
    output REG_IDX       [N-1:0] src1s,
    output REG_IDX       [N-1:0] src2s,
    output REG_IDX       [N-1:0] dsts,
    output PHYS_REG_IDX  [N-1:0] ts,
        // To: Map table
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!

    input logic        [N-1:0] cpl1s,
    input logic        [N-1:0] cpl2s,
        // From: Map table
        // - src1s, src2s is_complete bits resp.
    input PHYS_REG_IDX [N-1:0] t1s,
        // From: Map table
        // - Renamed physical registers tags for src1s
        // - src1[i] -> t1[i]
    input PHYS_REG_IDX [N-1:0] t2s
        // From: Map table
        // - Renamed physical registers tags for src2s
        // - src2[i] -> t2[i]
);
endmodule

/* 
================================================
Free List
================================================
*/
module free_list #(parameter 
    N=`N
) (
    input clock, reset, flush,
    // retire
    input struct packed {
        logic     [$clog2(N):0]   r_en_cnt;
            // From: retire (ROB)
            // - number of enabled retire lines WHO ARE RETURNING/DEALLOC'ING A PREG
            //   (e.g. no stores)
            //   (i.e. may only be a strict subset of retiring insns!)
            // - Question: Does this really need to be an count? Surely there isn't
            //   any serial dep. between returning pregs no? But again, the free list
            //   itself is likely going to be FIFO so I'm not sure what's more performant...
            //   enable bus vs. count?
        PHYS_REG_IDX [N-1:0]     r_tolds;
            // From: retire (ROB)
            // - pregs being returned to free list
    } r_in,

    // complete ?? 
    // issue ??

    // dispatch
    input struct packed {
        logic     [$clog2(N):0]   d_en_cnt;
            // From: dispatch
            // - number of enabled dispatch lines WHO NEED A DEST PREG 
            //   (e.g. no stores)
            //   (i.e. may only be a strict subset of dispatching insns!)
            // - depends on d_out.free_rdy_scnt

    } d_in,
    
    output struct packed {
        logic    [$clog2(N):0]   free_rdy_scnt;
            // To: dispatch
            // - sat. count of number of free pregs in free list;
            //   count reflects any pregs returned in retire! (i.e. AFTER retires)
            // - depends on r_in
        PHYS_REG_IDX [N-1:0]     d_ts;
            // To: dispatch
            // - newly allocated pregs
            // - depends on d_in.d_en_cnt
    } d_out
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
module map_table #(parameter 
    N=`N,
    RS_SZ=`RS_SZ
) (
    input clock, reset,
    // retire ??

    // complete
    input struct packed {
        logic         [N-1:0] c_en;
            // - Enabled complete lines?
        PHYS_REG_IDX  [N-1:0] c_ts; // tags
            // From: complete (EX)
    } c_in,

    // issue ??

    // dispatch
    input struct packed {
        logic         [$clog2(N):0] en_cnt;
            // - Number of enabled dispatch lines?
            // - NOTE: For in-order stuff with serial deps (like dispatch), use c(ou)nts;
            // otherwise use en(able) buses.
        REG_IDX       [N-1:0] src1s;
        REG_IDX       [N-1:0] src2s;
        REG_IDX       [N-1:0] dsts;
        PHYS_REG_IDX  [N-1:0] ts;
            // From: dispatch
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } d_in,
    output struct packed {
        logic        [N-1:0] cpl1s;
        logic        [N-1:0] cpl2s;
            // To: dispatch
            // - src1s, src2s is_complete bits resp.
        PHYS_REG_IDX [N-1:0] t1s;
            // To: dispatch
            // - Renamed physical registers tags for src1s
            // - src1[i] -> t1[i]
        PHYS_REG_IDX [N-1:0] t2s;
            // To: dispatch
            // - Renamed physical registers tags for src2s
            // - src2[i] -> t2[i]
    } d_out
);
endmodule

/* 
================================================
Architectural Map
================================================
*/
// Comments:
// - similar to map table, submodule to ROB?
module arch_map #(parameter 
    N=`N
) (
    input clock, reset,
    // retire
    input struct packed {
        logic         [$clog2(N):0] en_cnt;
            // - Number of enabled retire lines?
            // - Question: Does this need to be a count, or can we make it an enable
            // bus? I fear that there can be serial dependencies and ordering issues
            // e.g. if multiple insns retire to the same dest arch register.
        REG_IDX       [N-1:0] dsts;
        PHYS_REG_IDX  [N-1:0] ts;
            // From: retire (ROB)
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } r_in

    // complete ??
    // issue ??
    // dispatch ??
);
endmodule

/* 
================================================
(physical) Register File
================================================
*/
module prf (
    input clock, reset, flush,
    // retire ??

    // complete (write)
    input logic         [N-1:0] c_en,
        // - Enabled complete lines?
    input PHYS_REG_IDX  [N-1:0] c_ts, // tags
    input DATA          [N-1:0] c_vs, // vals
        // From: complete (EX)

    // issue (read)
    output DATA         [31:0]  state,
        // To: EX
        // - RF state after propagated completes
        // - we just expose the damn thing to EX, who seems to be the only consumer
        //   (insns issued just from RS to EX should read operands same-cycle)
        // - Question: My idea is just to let potentially any FU in EX to index 
        //   into the prf and get the operands it needs. So if there are 32 FUs,
        //   is this like 32 * 2 implicit read ports? (Same implicit read port
        //   concern as cpl_lst's)
    input logic         [N-1:0] s_en,
    input PHYS_REG_IDX  [N-1:0] s_t1s,
    input PHYS_REG_IDX  [N-1:0] s_t2s,
    output logic        [N-1:0] s_v1s,
    output logic        [N-1:0] s_v2s
        // To: EX/RS/issuer idk
        // - Explicit read ports for issuing insns to collect operands (alternative to state) 
        // - Have 2N read ports and only allow N issues per cycle. But problem: 
        //   If an insn can issue but is prevented from doing so due to issue
        //   limit, presumably it wont be able to collect operand in that cycle right?
        //   But what happens if some other insn writes to the same operand preg
        //   in the next cycle; it would overwrite the correct value? But then AHA,
        //   THERE CANT BE ANOTHER IDIOT WRITING TO THE SAME PREG CAN IT? So this 
        //   seems to be a non-issue after all. Remember, another insn can only have
        //   same dst in r10k after the one writing to it RETIRES.


    // dispatch ??
);
endmodule
