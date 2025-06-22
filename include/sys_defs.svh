/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  sys_defs.svh                                        //
//                                                                     //
//  Description :  This file defines macros and data structures used   //
//                 throughout the processor.                           //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`ifndef __SYS_DEFS_SVH__
`define __SYS_DEFS_SVH__

`include "timescale.svh"
`include "util_macros.svh"
`include "config.svh"
`include "types.svh"
`include "mem.svh"
`include "frontend.svh"


////////////////////////////////
// ---- Datapath Packets ---- //
////////////////////////////////

/**
 * Packets are used to move many variables between modules with
 * just one datatype, but can be cumbersome in some circumstances.
 *
 * Define new ones in project 4 at your own discretion
 */

/**
 * Commit Packet:
 * This is an output of the processor and used in the testbench for counting
 * committed instructions
 *
 * It also acts as a "WB_PACKET", and can be reused in the final project with
 * some slight changes
 */
typedef struct packed {
    `CNT_TYPE(N) r_en_cnt;
    logic   [N-1:0] halt;
    logic   [N-1:0] illegal;
} COMMIT_PACKET;

typedef struct packed {
    logic           cpl;
    PHYS_REG_IDX    tag;
    PHYS_REG_IDX    t_old;
    REG_IDX         dst;

    FU_IDX          fu_idx;
    logic           halt;
    logic           illegal;
} ROB_ENTRY;

typedef struct packed {
    DWADDR              dw;
    logic   [1:0][3:0]  off;
        // FB_OFF[1:0][1:0]ixq_out_off,
    logic   [1:0]       fmsk;
    logic   [1:0]       is_end;
} pc_gen2ixq;


typedef struct packed {
    // for reading
    BTQ_IDX [NUM_FU_BRU-1:0] btq_idx;

    struct packed {
        logic   en;
        // BTQ-specific completion stuff
        BTQ_IDX btq_idx; 
            // Entries to which we are completing
        logic   take;
        WADDR   tgt;
    } [NUM_FU_BRU-1:0] dat;
} execute2btq;


// branch completion bus
typedef struct packed {
    logic   [NUM_FU_BRU-1:0] en;
    
    // BTQ-specific completion stuff
    struct packed {
        BTQ_IDX btq_idx; 
            // Entries to which we are completing
        logic   take;
        WADDR   tgt;
        logic   [`IDX_SIZE(GHR_BUF_SZ)-1:0] ghr_base;
    } [NUM_FU_BRU-1:0] dat;
} execute2complete_bru;

typedef struct packed {
    // WADDR [NUM_FU_BRU-1:0] PC; // Does BRU need to carry PC if we can supply it like so?
    logic [NUM_FU_BRU-1:0] is_tail;
    logic [NUM_FU_BRU-1:0] pred;
    WADDR [NUM_FU_BRU-1:0] pred_tgt;
    logic [NUM_FU_BRU-1:0][3:0] pc_off;
    logic [NUM_FU_BRU-1:0][`IDX_SIZE(GHR_BUF_SZ)-1:0] ghr_base;
} btq2execute;

typedef struct packed {
    `CNT_TYPE(N) r_en_cnt; // final final
    PHYS_REG_IDX [N-1:0]   tag;
    PHYS_REG_IDX [N-1:0]   t_old;
    REG_IDX      [N-1:0]   dst;
    logic        [N-1:0]   halt;
    logic        [N-1:0]   illegal;
} retire_final;

// Reservation station stuff
parameter RS_ALU_SZ     = 8;
parameter RS_MUL_SZ    = 8;
parameter RS_LOD_SZ    = 4;
parameter RS_STOR_SZ    = 4;
parameter RS_BRU_SZ     = 4;
typedef struct packed {
`ifdef DEBUG
    int             id; // debug only; unique insn identifier
`endif
    BMASK           bmask;

    WADDR           PC;
    INST            inst;
    // IDEA: carry the imm (decode it in stage_id) instead of inst

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy; // completed? should we rename to cpl for consistency?
    logic           t2_rdy;
    ROB_IDX         rob_idx;

    ALU_OPA_SELECT  opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT  opb_select; // ALU opb mux select (ALU_OPB_xxx *)
    ALU_FUNC        alu_func;   // ALU function select (ALU_xxx *)
} RS_ALU_PAYLOAD;

typedef struct packed {
`ifdef DEBUG
    int             id;
    WADDR           PC;
    INST            inst;
`endif
    BMASK           bmask;

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy;
    logic           t2_rdy;
    ROB_IDX         rob_idx;
    MUL_FUNC       func;
} RS_MUL_PAYLOAD;

typedef struct packed {
`ifdef DEBUG
    int             id;
    WADDR           PC;
    INST            inst;
`endif
    /* FIXME: stubbed */
    logic _dummy;
} RS_LOAD_PAYLOAD;

typedef struct packed {
`ifdef DEBUG
    int             id;
    WADDR           PC;
    INST            inst;
`endif
    /* FIXME: stubbed */
    logic _dummy;
} RS_STOR_PAYLOAD;

typedef struct packed {
`ifdef DEBUG
    int             id;
`endif
    BMASK           b1hot;
    BMASK           bmask;

    WADDR           PC;
    INST            inst;
    // IDEA: carry the imm (decode it in stage_id) instead of inst

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy; // completed? should we rename to cpl for consistency?
    logic           t2_rdy;
    ROB_IDX         rob_idx;

    ALU_OPA_SELECT  opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT  opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    BTQ_IDX         btq_idx;
    logic           cond_branch;
} RS_BRU_PAYLOAD;

/* 
The following structs are enrichments of the previous.
ID_RESULT -> ALLOC_RENAME_PKT -> RENAME_COMMIT_PKT -> COMMIT_RS_PKT
*/
typedef struct packed {
`ifdef DEBUG
    int             id;
`endif
    WADDR           PC;
    INST            inst;
    FU_IDX          fu_idx;

    ALU_FUNC        alu_func;   // ALU function select (ALU_xxx *)
    ALU_OPA_SELECT  opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT  opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    logic           has_dst;    // does insn have destination register?
    logic           cond_branch;// Is inst a conditional branch? (0 = not branch OR not cond_branch, 1 = cond_branch)
    logic           halt;       // Is this a halt?
    logic           illegal;    // Is this instruction illegal?
    logic           csr_op;     // Is this a CSR operation? (we only used this as a cheap way to get return code)
    RAS_SNAP        ras_snap;
    BTQ_IDX         btq_idx;
} ID_RESULT;

typedef struct packed {
    // from ID_RESULT
`ifdef DEBUG
    int             id;
`endif
    WADDR           PC;
    INST            inst;
    FU_IDX          fu_idx;

    ALU_FUNC        alu_func;   // ALU function select (ALU_xxx *)
    ALU_OPA_SELECT  opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT  opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    logic           has_dst;    // does insn have destination register?
    logic           cond_branch;// Is inst a conditional branch? (0 = not branch OR not cond_branch, 1 = cond_branch)
    logic           halt;       // Is this a halt?
    logic           illegal;    // Is this instruction illegal?
    logic           csr_op;     // Is this a CSR operation? (we only used this as a cheap way to get return code)
    BTQ_IDX         btq_idx;

    // alloc
    PHYS_REG_IDX    t;
    `IDX_TYPE(ROB_SZ) fl_head_snap;
} ALLOC_RENAME_PKT;

typedef struct packed {
    // from ID_RESULT
`ifdef DEBUG
    int             id;
`endif
    WADDR           PC;
    INST            inst;
    FU_IDX          fu_idx;

    ALU_FUNC        alu_func;   // ALU function select (ALU_xxx *)
    ALU_OPA_SELECT  opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT  opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    logic           has_dst;    // does insn have destination register?
    logic           cond_branch;// Is inst a conditional branch? (0 = not branch OR not cond_branch, 1 = cond_branch)
    logic           halt;       // Is this a halt?
    logic           illegal;    // Is this instruction illegal?
    logic           csr_op;     // Is this a CSR operation? (we only used this as a cheap way to get return code)
    BTQ_IDX         btq_idx;

    // alloc
    PHYS_REG_IDX    t;
    // rename
    BMASK           b1hot;
    PHYS_REG_IDX    t_old;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
} RENAME_COMMIT_PKT;

typedef struct packed {
    // from ID_RESULT
`ifdef DEBUG
    int             id;
`endif
    WADDR           PC;
    INST            inst;
    FU_IDX          fu_idx;

    ALU_FUNC        alu_func;   // ALU function select (ALU_xxx *)
    ALU_OPA_SELECT  opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT  opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    logic           has_dst;    // does insn have destination register?
    logic           cond_branch;// Is inst a conditional branch? (0 = not branch OR not cond_branch, 1 = cond_branch)
    logic           halt;       // Is this a halt?
    logic           illegal;    // Is this instruction illegal?
    logic           csr_op;     // Is this a CSR operation? (we only used this as a cheap way to get return code)
    BTQ_IDX         btq_idx;

    // alloc
    PHYS_REG_IDX    t;
    // rename
    BMASK           b1hot;
    BMASK           bmask;
    PHYS_REG_IDX    t_old; // should be unused in RS
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy;
    logic           t2_rdy;
    // commit
    ROB_IDX         rob_idx;
} COMMIT_RS_PKT; // purely combinational


// By Fetch
typedef struct packed {
    // insn md flattened
    logic   [N-1:0]    brch, cond, call, ret;
    WADDR   [N:0]      PC_n; // branch pc
    logic   [N:0][`CNT_SIZE(N)-1:0] brch_prefix_cnt;

    `CNT_TYPE(N)       f_cnt;
    logic   [N-1:0]    f_en;
} fetch2bp;

typedef struct packed {
    // fetch sublimit
    `CNT_TYPE(N) lim_cnt; // f_cnt limit (cap at first taken)
    `CNT_TYPE(N) ghr_rdy_scnt;

    // btq_entry contributions
    logic   [N-1:0] take;
    WADDR   [N-1:0] tgt;
    logic   [N-1:0][GHR_LEN-1:0] hash;

    // if_id_packet contributions
    RAS_SNAP[N-1:0] ras_snap;
    logic   [N-1:0][`IDX_SIZE(GHR_BUF_SZ)-1:0] ghr_base;
    logic   [N-1:0] pred_gshare;
    logic   [N-1:0] pred_bim;
} bp2fetch;

typedef struct packed {
    `CNT_TYPE(N)   f_en_cnt;
    IF_ID_PACKET    [N-1:0]    f_dat;
} fetch2decode;

typedef struct packed {
    WADDR [N-1:0] pc;
} fetch2btb;

typedef struct packed {
    logic [N-1:0] vld; // i.e. hit?
    WADDR [N-1:0] tgt;
} btb2fetch;

// By decode
typedef struct packed {
    `CNT_TYPE(N) d_rdy_cnt;
} decode2fetch;

typedef struct packed {
    DWADDR [N-1:0] PCdws; // PC double word indices
} fetch2mem;

typedef struct packed {
    MEM_BLOCK   [N-1:0] data;
    BRANCH_MD   [N-1:0][1:0] insn_md; // [dw][w]
} mem2fetch;

typedef struct packed {
    `CNT_TYPE(N) d_vld_scnt;
    ID_RESULT   [N-1:0]        d_dat;
} decode2dispatch;

// By Arch Map
parameter int NUM_ARCH_REG = 32;
typedef struct packed {
    PHYS_REG_IDX [NUM_ARCH_REG-1:0] entries;
} arch_map2map_table;

// By Dispatch
typedef struct packed {
    // NOTE: This is the only place where a transaction is
    // RECEIVER-decided!!! (i.e. receiver broadcasts enable signals)
    `CNT_TYPE(N) dispatch_en_cnt;
} dispatch2decode;

typedef struct packed {
    `CNT_TYPE(N) snap_en_cnt;
} rename2bman;

typedef struct packed {
    `CNT_TYPE(N) snap_rdy_scnt;
    BMASK [N-1:0]  b1hot_n;
    BMASK [N:0]    bmask_n;
} bman2rename;

typedef struct packed {
    logic [N-1:0] snap_en;
    BMASK [N-1:0] b1hot_n;
`ifdef DEBUG
    BTQ_IDX [N-1:0] btq_idx;
`endif
    BTQ_IDX [N-1:0] btq_tail;
    logic [N-1:0][`IDX_SIZE(ROB_SZ)-1:0] fl_head;
    RAS_SNAP [N-1:0] ras_snap;
    // mt checkpoints are handled locally
} rename2snap_bus;

typedef struct packed {
    logic [N-1:0] snap_en;
    BMASK [N-1:0] b1hot_n;
    ROB_IDX [N-1:0] rob_tail;
} comm2snap_bus;

typedef struct packed {
    /* Alloc */
    /* Rename */
    /* Commit */
    logic   [FU_IDX_NUM-1:0][N-1:0] en;
        // - To: RS
        // - Number of enabled dispatch lines? (replacement for d_vld)
        // - Question: permit
        // 1) only N dispatches, OR
        // 2) a different limit number of dispatches DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
        // (DIS_MAX will be a new sys_defs.svh constant) ?
    COMMIT_RS_PKT [N-1:0] dat; //shouldn't have dispatch feed to RS,
        // - To: RS               //should come directly from dispatch
} dispatch2rs;

typedef struct packed {
    /* Rename */
    /* Commit */
    `CNT_TYPE(N) d_en_cnt;
        // To: ROB
        // - Number of enabled dispatch lines?
    PHYS_REG_IDX [N-1:0] tag;
    PHYS_REG_IDX [N-1:0] t_old;
        // From: dispatch
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    FU_IDX  [N-1:0] fu_idx;
    REG_IDX [N-1:0] dst;
    logic   [N-1:0] halt;
    logic   [N-1:0] illegal;
} dispatch2rob;

typedef struct packed {
    `CNT_TYPE(N) free_d_en_cnt;
        // To: Free list
        // - number of enabled dispatch lines WHO NEED A DEST PREG 
        //   (e.g. no stores)
        //   (i.e. may only be a strict subset of dispatching insns!)
} dispatch2free_list;

typedef struct packed {
    `CNT_TYPE(N) en_cnt;
        // - Number of enabled dispatch lines?
        // - NOTE: For in-order stuff with serial deps (like dispatch), use c(ou)nts;
        // otherwise use en(able) buses.
    REG_IDX       [N-1:0] src1s;
    REG_IDX       [N-1:0] src2s;
    REG_IDX       [N-1:0] dsts;
    PHYS_REG_IDX  [N-1:0] ts;
        // To: Map table
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
} dispatch2map_table;


// By Map Table
typedef struct packed {
    PHYS_REG_IDX [N-1:0] t1s;
    PHYS_REG_IDX [N-1:0] t2s;
    PHYS_REG_IDX [N-1:0] ts_old;
} map_table2dispatch;

// By RS
typedef struct packed {
    logic   [FU_IDX_NUM-1:0][N-1:0] rdy_sbus;
        // - From: RS
} rs2dispatch;

typedef struct packed {
    logic bypass1;
    logic bypass2;
    `IDX_TYPE(N) cdb_idx1;
    `IDX_TYPE(N) cdb_idx2;
} BYPASS_TAG;

typedef struct packed {
    /* Requested by issue arbiter 
    (only ALU needs gnt by CDB arbiter to 'en')*/
    logic [NUM_FU_ALU-1:0] fu_vld_alu;
    logic [NUM_FU_BRU-1:0] fu_vld_bru;

    /* Selected for issue */
    logic [NUM_FU_ALU-1:0] fu_en_alu;
    logic [NUM_FU_MUL-1:0] fu_en_mul;
    logic [NUM_FU_STR-1:0] fu_en_str;
    logic [NUM_FU_LOD-1:0] fu_en_lod;
    logic [NUM_FU_BRU-1:0] fu_en_bru;

    RS_ALU_PAYLOAD [NUM_FU_ALU-1:0] fu_dat_alu;
    RS_MUL_PAYLOAD [NUM_FU_MUL-1:0] fu_dat_mul;
    RS_ALU_PAYLOAD [NUM_FU_STR-1:0] fu_dat_str;
    RS_ALU_PAYLOAD [NUM_FU_LOD-1:0] fu_dat_lod;
    RS_BRU_PAYLOAD [NUM_FU_BRU-1:0] fu_dat_bru;

    BYPASS_TAG [NUM_FU_ALU-1:0] bytag_alu;
    BYPASS_TAG [NUM_FU_BRU-1:0] bytag_bru;
} rs2execute;

// By ROB
typedef struct packed {
    `CNT_TYPE(N)rob_rdy_scnt;
        // From: ROB
        // saturating counter for number of free rob entries
    ROB_IDX [N:0] rob_idxs_n;
        // To: dispatch
        // rob idxs of entries that can be allocated this cycle
} rob2dispatch;

typedef struct packed {
    `CNT_TYPE(N) r_vld_cnt;
        // From: retire (ROB)
        // - number of valid retire lines
    ROB_ENTRY   [N-1:0]        entries; 
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
} rob2retire;

// By Execute
typedef struct packed {
    logic       [NUM_FU_ALU-1:0]   fu_rdy_alu;
    logic       [NUM_FU_MUL-1:0]  fu_rdy_mul;
    logic       [NUM_FU_STR-1:0]   fu_rdy_str;
    logic       [NUM_FU_LOD-1:0]  fu_rdy_lod;
    logic       [NUM_FU_BRU-1:0]   fu_rdy_bru;

    logic       [NUM_FU_ALU-1:0]   fu_cdb_gnt_alu; // 1-cycle insns need to win CDB arb. to issue
    logic       [NUM_FU_BRU-1:0]   fu_cdb_gnt_bru; // 1-cycle insns need to win CDB arb. to issue
} execute2rs;

typedef struct packed {
    logic           [N-1:0] en;
    PHYS_REG_IDX    [N-1:0] ts;
} execute2complete_tag;

typedef struct packed {
    logic           [N-1:0] en;
    PHYS_REG_IDX    [N-1:0] ts;
        // - From: EX
    ROB_IDX         [N-1:0] rob_idxs;
        // - From: EX
    DATA            [N-1:0] data;
} execute2complete_dat;

// By Free List
typedef struct packed {
    `CNT_TYPE(N) free_rdy_scnt;
        // From: Free list
        // - sat. count of number of free pregs in free list;
        //   count reflects any pregs returned in retire! (i.e. AFTER retires)
    PHYS_REG_IDX [N-1:0]   d_ts;
        // From: Free list
        // - newly allocated pregs

    logic [N:0][`IDX_SIZE(ROB_SZ)-1:0] fl_heads_n;
} free_list2dispatch;

`define BY_FU(type) \
struct packed { \
    type [NUM_FU_ALU-1:0]  alu; \
    type [NUM_FU_MUL-1:0]  mul; \
    type [NUM_FU_LOD-1:0]  lod; \
    type [NUM_FU_STR-1:0]  str; \
    type [NUM_FU_BRU-1:0]  bru; \
}

typedef struct packed {
    `BY_FU(logic)           en1s;
    `BY_FU(logic)           en2s;
    `BY_FU(PHYS_REG_IDX)    t1s;
    `BY_FU(PHYS_REG_IDX)    t2s;
} execute2prf;

typedef struct packed{
    `BY_FU(DATA)    v1s;
    `BY_FU(DATA)    v2s;
} prf2execute;

localparam FL_DEPTH = ROB_SZ;
localparam FL_WIDTH = $bits(PHYS_REG_IDX);
typedef struct packed {
    retire_final r_in;
    dispatch2free_list d_in;
    free_list2dispatch d_out;
    struct packed {
        logic [FL_DEPTH-1:0][FL_WIDTH-1:0] state;
        `IDX_TYPE(FL_DEPTH) head, tail;
        `CNT_TYPE(FL_DEPTH) used;
    } fifo;
} DBG_fl;



`ifdef DEBUG
// OPTIONAL: Print our your data here
// It will go to the $program.log file
function print_id_result(input ID_RESULT x);
    $display("ID_RESULT: id=%3d PC=%h fu_idx=%2d inst=%h opa_select=%1d opb_select=%1d alu_func=%1d cond_branch=%b halt=%b illegal=%b csr_op=%b btq_idx=%2d ",
        x.id,
        x.PC,
        x.fu_idx,
        x.inst,
        x.opa_select,
        x.opb_select,
        x.alu_func,
        x.cond_branch,
        x.halt,
        x.illegal,
        x.csr_op,
        x.btq_idx
    );
endfunction

function print_commit_rs_pkt(input COMMIT_RS_PKT x);
    $display("COMMIT_RS_PKT: {bmask: %b} id=%3d PC=%h fu_idx=%2d inst=%h opa_select=%1d opb_select=%1d alu_func=%1d cond_branch=%b halt=%b illegal=%b csr_op=%b btq_idx=%2d b1hot=%b",
        x.bmask,
        x.id,
        x.PC,
        x.fu_idx,
        x.inst,
        x.opa_select,
        x.opb_select,
        x.alu_func,
        x.cond_branch,
        x.halt,
        x.illegal,
        x.csr_op,
        x.btq_idx,
        x.b1hot
    );
endfunction

function get_fu_name(input FU_IDX fu_idx, output string name);
    case (fu_idx)
        FU_ALU:  name = "ALU";
        FU_MUL: name = "MUL";
        FU_LOD: name = "LOD";
        FU_STR:  name = "STR";
        FU_BRU:  name = "BRU";
        default: name = "Unknown FU";
    endcase
endfunction

function automatic string dbg_mem_cmd(input MEM_COMMAND cmd);
    string rv;
    case (cmd)
        MEM_NONE:  rv = "NONE";
        MEM_STORE: rv = "STOR";
        MEM_LOAD:  rv = "LOAD";
    endcase
    return rv;
endfunction

function automatic string dbg_mem_size(input MEM_SIZE size);
    string rv;
    rv = "unknown mem size";
    case (size)
        BYTE:   rv = "BYTE";
        HALF:   rv = "HALF";
        WORD:   rv = "WORD";
        DOUBLE: rv = "DOUBLE";
    endcase
    return rv;
endfunction;
`endif

`endif // __SYS_DEFS_SVH__
