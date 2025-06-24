`ifndef __SYS_DEFS_SVH__
`define __SYS_DEFS_SVH__

`include "ISA.svh"

// all files should `include "sys_defs.svh" to at least define the timescale
`timescale 1ns/100ps


// ================
// Macros
// ================

`define MIN(a, b) ((a) < (b) ? (a) : (b))
`define MAX(a, b) ((a) > (b) ? (a) : (b))

`define CNT_TYPE(max) logic [$clog2(max+1)-1:0] // smallest bit-vector to store max
`define CNT_SIZE(max) ($clog2(max+1))           // ...and number of bits in that type

`define IDX_TYPE(len) logic [$clog2(len)-1:0]   // smallest bit-vector to index an array of length len
`define IDX_SIZE(len) ($clog2(len))             // ...and number of bits in that type

`define UCAST_LEN(n, max) ($clog2(max+1)'(unsigned'(n)))
`define UCAST_FIT(n) (($clog2(n+1))'(unsigned'(n)))    // cast fit unsigned


// ================
// Compil. Controls
// ================

// `define SYNTH // synth only constructions // FIXME: how can we implement this in Makefile?

`ifndef SYNTH
// `define DEBUG
// `define CYCLE_PRINT // clock cycle print
// `define PC_GEN_TEST_MODE
`define FORMAL
`endif

/* Memory config */
`define CACHE_MODE
    // Cache mode removes the byte-level interface from memory, so it always returns
    // a double word. The original processor won't work with this defined. Your new
    // processor will have to account for this effect on mem.
    // Notably, you can no longer write data without first reading.
    // TODO: uncomment this line once you've implemented your cache


// ================
// Parameters
// ================

// some starting parameters that you should set
// this is *your* processor, you decide these values (try analyzing which is best!)

// you are not allowed to change this definition for your final processor
// the project 3 processor has a massive boost in performance just from having no mem latency
// see if you can beat it's CPI in project 4 even with a 100ns latency!
//`define MEM_LATENCY_IN_CYCLES  0
`define MEM_LATENCY_IN_CYCLES (100.0/`CLOCK_PERIOD+0.49999)
// the 0.49999 is to force ceiling(100/period). The default behavior for
// float to integer conversion is rounding to nearest

// memory tags represent a unique id for outstanding mem transactions
// 0 is a sentinel value and is not a valid tag
`define NUM_MEM_TAGS 15

`define MEM_SIZE_IN_BYTES (64*1024)
`define MEM_64BIT_LINES   (`MEM_SIZE_IN_BYTES/8)


parameter N = 2;    // superscalar width
// parameter CDB_SZ= N // This MUST match your superscalar width

// bpu
    // FTB entry config
parameter NUM_BR_SLOTS  = 2;
parameter MAX_FB_SPAN   = 16; // maximum span of a fetch block (in words/insns)
    // ^^ WARNING: many of the fetch/BPU structures are hardcoded, independent of these params

parameter BRANCH_PRED_SZ= 'x; // FIXME
parameter GHR_BUF_SZ    = 32;
parameter GHR_LEN       = 8;
parameter RAS_SZ        = 16;
parameter FTQ_SZ        = 32;

// fetch
parameter IQQ_SZ        = 4;
parameter IRQ_SZ        = 8;
parameter BTQ_SZ        = 16;
    // (BTQ_SZ doubled from 8. This improved CPI on tight loop programs like
    // branchy.s and branchy_nested.s.)

// rename/checkpoints
parameter BMASK_LEN     = 8; // i.e. number of branch checkpoints
parameter ROB_SZ        = 64;
parameter FREE_LIST_SZ  = ROB_SZ;

// reservation station
    // num entries per partition
parameter RS_ALU_SZ     = 8;
parameter RS_MUL_SZ     = 8;
parameter RS_LOD_SZ     = 4;
parameter RS_STOR_SZ    = 4;
parameter RS_BRU_SZ     = 4;

// execute
    // functional units (you should decide if you want more or fewer types of FUs)
parameter NUM_FU_ALU    = 2;
parameter NUM_FU_MUL    = 1;
parameter NUM_FU_LOD    = 1;
parameter NUM_FU_STR    = 1;
parameter NUM_FU_BRU    = 1;
parameter NUM_FU_TOTAL  = NUM_FU_ALU + NUM_FU_MUL + NUM_FU_LOD + NUM_FU_STR + NUM_FU_BRU;
    // per-FU config
parameter LD_BAY_SZ     = 2; // number of load bays in load FU
parameter MUL_STAGES    = 16;// number of mult stages (2, 4) (you likely don't need 8)
    // Justin: funny enough we need at least 8 or else multiply is on critical path

parameter PHYS_REG_SZ_P6    = 32;
parameter PHYS_REG_SZ_R10K  = (32 + ROB_SZ);

// worry about these later
parameter DCACHE_LINES  = 32;
parameter LSQ_SZ        = 12;
parameter SQ_RET_BUF_SZ = 4;


// ================
// Types
// ================

// index types
typedef logic [4:0]  REG_IDX;
typedef `IDX_TYPE(PHYS_REG_SZ_R10K) PHYS_REG_IDX;
    /* NOTE: PHYS_REG_IDX = 0 is a sentinel (to denote "no register" / "is immediate operand").
    While we lose out on a single physical register, this greatly simplifies logic 
    (the alternative is to pipe around 'is valid src_reg' bit signals everywhere). */
typedef `IDX_TYPE(BTQ_SZ) BTQ_IDX;
typedef `IDX_TYPE(ROB_SZ) ROB_IDX;
typedef `IDX_TYPE(LSQ_SZ) LSQ_IDX;
typedef `IDX_TYPE(GHR_BUF_SZ) GHR_IDX;

// superscalar-width convenience types
typedef `CNT_TYPE(N) N_CNT;
typedef `CNT_TYPE(N) N_IDX;

// address types
typedef logic [31:0] ADDR;  // full address
typedef logic [15:0] BADDR; // address (restricted to only used 16 LSB). i.e. byte index
typedef logic [14:0] HADDR; // half index
typedef logic [13:0] WADDR; // word index
typedef logic [12:0] DWADDR;// double-word (dw) index

typedef logic [BMASK_LEN-1:0] BMASK;

// address conversion functions
    // addr <-> double-word
function automatic DWADDR   addr2dw(input ADDR addr);   return addr[15:3];          endfunction
function automatic ADDR     dw2addr(input DWADDR addr); return {16'b0, addr, 3'b0}; endfunction
    // addr <-> word
function automatic WADDR    addr2w(input ADDR addr);    return addr[15:2];          endfunction
function automatic ADDR     w2addr(input WADDR addr);   return {16'b0, addr, 2'b0}; endfunction

    // in-word byte offset
function automatic logic[1:0] iw_off(input ADDR addr);  return addr[1:0];           endfunction
    // in-double-word byte offset
function automatic logic[2:0] idw_off(input ADDR addr); return addr[2:0];           endfunction

// word and register sizes
typedef logic [31:0] DATA;
typedef union packed {
    logic [3:0][7:0]  byte_level;
    logic [1:0][15:0] half_level;
    logic      [31:0] word_level;
} DATA_BLOCK;
typedef union packed {
    logic [7:0][7:0]  byte_level;
    logic [3:0][15:0] half_level;
    logic [1:0][31:0] word_level;
    logic      [63:0] dbbl_level;
} MEM_BLOCK;

typedef logic [3:0]  MEM_TAG;
typedef enum logic [1:0] {
    BYTE   = 2'h0,
    HALF   = 2'h1,
    WORD   = 2'h2,
    DOUBLE = 2'h3
} MEM_SIZE;
// Memory bus commands
typedef enum logic [1:0] {
    MEM_NONE = 2'h0,
    MEM_LOAD = 2'h1,
    MEM_STORE= 2'h2
} MEM_COMMAND;


parameter FU_IDX_NUM = 5;
typedef enum logic [2:0] {
    FU_ALU  = 'd0,
    FU_MUL  = 'd1,
    FU_LOD  = 'd2,
    FU_STR  = 'd3,
    FU_BRU  = 'd4
} FU_IDX;


// ================
// Basic constants
// ================

// NOTE: the global CLOCK_PERIOD is defined in the Makefile

// useful boolean single-bit definitions
`define FALSE 1'h0
`define TRUE  1'h1

// the zero register
// In RISC-V, any read of this register returns zero and any writes are thrown away
`define ZERO_REG 5'd0

// Basic NOP instruction. Allows pipline registers to clearly be reset with
// an instruction that does nothing instead of Zero which is really an ADDI x0, x0, 0
`define NOP 32'h00000013


// ================
// Datapath control signals
// ================

// ALU opA input mux selects
typedef enum logic [1:0] {
    OPA_IS_RS1  = 2'h0,
    OPA_IS_NPC  = 2'h1,
    OPA_IS_PC   = 2'h2,
    OPA_IS_ZERO = 2'h3
} ALU_OPA_SELECT;

// ALU opB input mux selects
typedef enum logic [3:0] {
    OPB_IS_RS2    = 4'h0,
    OPB_IS_I_IMM  = 4'h1,
    OPB_IS_S_IMM  = 4'h2,
    OPB_IS_B_IMM  = 4'h3,
    OPB_IS_U_IMM  = 4'h4,
    OPB_IS_J_IMM  = 4'h5
} ALU_OPB_SELECT;

// ALU function code
typedef enum logic [3:0] {
    ALU_ADD     = 4'h0,
    ALU_SUB     = 4'h1,
    ALU_SLT     = 4'h2,
    ALU_SLTU    = 4'h3,
    ALU_AND     = 4'h4,
    ALU_OR      = 4'h5,
    ALU_XOR     = 4'h6,
    ALU_SLL     = 4'h7,
    ALU_SRL     = 4'h8,
    ALU_SRA     = 4'h9
} ALU_FUNC;

// MULT funct3 code
// we don't include division or rem options
typedef enum logic [2:0] {
    M_MUL,
    M_MULH,
    M_MULHSU,
    M_MULHU
} MUL_FUNC;

typedef enum logic [1:0] {
    FIFO_FLUSH_RESET     = 0, // default
    FIFO_FLUSH_SNAP_HEAD = 1, // wind head to checkpoint
    FIFO_FLUSH_SNAP_TAIL = 2  // wind tail to checkpoint
} FIFO_FLUSH_MODE;

typedef enum logic [1:0] {
    SKID_FLUSH_RESET  = 0,
    SKID_FLUSH_MASK   = 1,
    SKID_FLUSH_IGNORE = 2
} SKID_FLUSH_MODE;


// ================
// Owner: BPU (branch prediction unit)
// ================
typedef enum logic [1:0] {
    SN = 2'b00,
    WN = 2'b01,
    WT = 2'b10,
    ST = 2'b11
} SC_STATE;

function automatic logic [1:0] update_sc(
    input logic unsigned [1:0] sc,
    input logic take
);
    if (take)
        return sc == 2'b11 ? 2'b11 : sc + `UCAST_FIT(1);
    else
        return sc == 0 ? 0 : sc - `UCAST_FIT(1);
endfunction

function automatic logic query_sc(input logic [1:0] sc);
    return sc[1];
endfunction

// Packets: BPU
typedef struct packed {
    logic [1:0] sc;
    logic       vld;
    WADDR       tgt;
    logic [3:0] off;
        /* TODO (critical path opt.): Use either...
            A. cry, lo4 scheme:
                cry = idx-4 carry bit,
                lo4 = lowest 4 bits of branch pc
                pc  = {base + cry, lo4}
                ++ cheap to reconstruct pc (simply concat lowest bits)
                -- costlier update_fb offset comparisons

            B. cry, off scheme:
                cry = same as above
                off = pc - base
                pc  = {base + cry, (base + off)[3:0]}
                -- costlier to reconstruct pc (add offset)
                ++ cheaper update_fb offset comparisons

            Maybe lo4 for fallthrough (end_off), off for branch fb_off?
        */
    logic       always_take; // i.e. a cond branch that is always taken?
} FTB_BR_SLOT;

typedef struct packed {
    logic cond;         // = "sharing" bit
    logic call;
    logic ret;
    logic jalr;
} FTB_MD1;

typedef struct packed {
    // fallthrough npc (i.e. npc if no branch taken)
    logic [3:0] end_off;    // offset of last insn in the FB. ft_npc = base + end_off + 1
        // TODO: see FTB_BR_SLOT (above) for alternative schemes

    // two branch slots: [0, 1]
    FTB_BR_SLOT [1:0] br_slot;

    // metadata re: br1/tail slot
    FTB_MD1 md1;
} FTB_ENTRY;

typedef struct packed {
    WADDR       base;
    logic [3:0] fb_off; // pc = base + fb_off
    logic       take;
    WADDR       tgt;

    FTB_MD1 md;
} FTB_UPD_PKT;

typedef struct packed {
    // FTB_UPD_PKT fields
    WADDR       base;
    logic [3:0] fb_off; // pc = base + fb_off
    logic       take;
    WADDR       tgt;

    logic       always_take; // i.e. a cond branch that is always taken?
    FTB_MD1     md;

    // predictor-specific fields
    logic       en_dir_update;  // update direction predictors?
    logic       slot_idx;
    logic [GHR_LEN-1:0] hash;   // gshare hash
} BPU_UPD_PKT;


// ================
// Owner: Fetch
// ================
// Packets: fetch
typedef struct packed {
    logic [N-1:0][`IDX_SIZE(RAS_SZ)-1:0] top;
    logic [N-1:0][`CNT_SIZE(RAS_SZ)-1:0] used;
} RAS_SNAP;

typedef struct packed {
`ifdef PC_GEN_TEST_MODE
    int id;
`endif
    // logic[GHR_LEN-1:0] hash;
    // GHR_IDX [1:0] ghr_base;

    WADDR       base_n;     // base address of *next* FB

    logic       ft;         // fallthrough? else took a branch
    logic       pred_idx;   // ft ? <IGNORE>: slot of pred-taken branch
    logic [3:0] off;        // ft ? end_off : slot[pred_idx].off
    logic       hit;

    // pared down FTB entry
    struct packed {
        logic       vld;
        logic [3:0] off;
    } [1:0] slot;

    logic       always_take;// ft ? <IGNORE>: " of pred-taken branch
    FTB_MD1     md;         // ft ? <IGNORE>: " of pred-tkaen branch
} FTQ_ENTRY;


typedef struct packed {
    // struct guard
    logic brch; // 1 iff is any form of control insn

    // fields valid iff branch high
    logic cond;
    logic call;
    logic ret;
    logic jalr;
} BRANCH_MD;

typedef struct packed {
    INST  inst;
    WADDR PC;

    RAS_SNAP ras_snap;
    BTQ_IDX btq_idx;
} IF_ID_PKT;

// I/O: fetch
typedef struct packed {
    DWADDR              dw;
    logic   [1:0][3:0]  off;
        // FB_OFF[1:0][1:0]ixq_out_off,
    logic   [1:0]       fmsk;
    logic   [1:0]       is_end;
} pc_gen2ixq;

typedef struct packed {
    DWADDR [N-1:0] PCdws; // PC double word indices
} fetch2mem;

typedef struct packed {
    MEM_BLOCK   [N-1:0] data;
    BRANCH_MD   [N-1:0][1:0] insn_md; // [dw][w]
} mem2fetch; // FIXME: mem-owned, not fetch-owned. Wrong section.

typedef struct packed {
    `CNT_TYPE(N)           wen_cnt;
        // How many branch instructions dispatching?
        // Sender must ensure branch insns packed to lowest indices.
    logic   [N-1:0]     is_tail;
    WADDR   [N-1:0]     PC;
    logic   [N-1:0][3:0]off;
    logic   [N-1:0]     pred;
    WADDR   [N-1:0]     pred_tgt;
    logic   [N-1:0]     always_take;
    FTB_MD1 [N-1:0]     md;

    logic   [N-1:0]     hit;
    logic   [N-1:0]     hit_slot;
    logic   [N-1:0]     slot_idx;
    logic   [N-1:0][GHR_LEN-1:0] hash; // gshare hash index
    GHR_IDX [N-1:0]     ghr_base;
} fetch2btq;

typedef struct packed {
    `CNT_TYPE(N)    wen_cnt;
    IF_ID_PKT   [N-1:0] dat;
} fetch2decode;

typedef struct packed {
    `CNT_TYPE(N)    rdy_scnt;
    BTQ_IDX [N-1:0] btq_idxs_n;

    logic       bpu_uen;
    BPU_UPD_PKT bpu_udat;
} btq2fetch;

typedef struct packed {
    // WADDR [NUM_FU_BRU-1:0] PC; // Does BRU need to carry PC if we can supply it like so?
    logic [NUM_FU_BRU-1:0] is_tail;
    logic [NUM_FU_BRU-1:0] pred;
    WADDR [NUM_FU_BRU-1:0] pred_tgt;
    logic [NUM_FU_BRU-1:0][3:0] fb_off;
    logic   [NUM_FU_BRU-1:0]ghr_vld;
    GHR_IDX [NUM_FU_BRU-1:0]ghr_base;
} btq2execute;

// ================
// Owner: Decode
// ================
// Packets: Decode
/* 
The following structs are enrichments of the previous.
ID_RENAME_PKT -> ALLOC_RENAME_PKT -> RENAME_COMMIT_PKT -> COMMIT_RS_PKT
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
} ID_RENAME_PKT;

// I/O: Decode
typedef struct packed {
    `CNT_TYPE(N)    rdy_scnt;
} decode2fetch;

typedef struct packed {
    `CNT_TYPE(N)    vld_scnt;
    ID_RENAME_PKT[N-1:0]dat;
} decode2dispatch;


// ================
// Owner: Dispatch
// ================
// Packets: Dispatch
typedef struct packed {
    // from ID_RENAME_PKT
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
    // from ID_RENAME_PKT
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

// I/O: Dispatch
typedef struct packed {
    // NOTE: This is the only place where a transaction is
    // RECEIVER-decided!!! (i.e. receiver broadcasts enable signals)
    `CNT_TYPE(N) ren_cnt;
} dispatch2decode;

typedef struct packed {
    `CNT_TYPE(N) snap_en_cnt;
} rename2bman;

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
    `CNT_TYPE(N) wen_cnt;
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
    `CNT_TYPE(N) ren_cnt;
        // To: Free list
        // - number of enabled dispatch lines WHO NEED A DEST PREG 
        //   (e.g. no stores)
        //   (i.e. may only be a strict subset of dispatching insns!)
} dispatch2free_list;


// ================
// Owner: ROB
// ================
// Packets: ROB
// I/O: ROB
typedef struct packed {
    `CNT_TYPE(N)    rdy_scnt;
        // From: ROB
        // saturating counter for number of free rob entries
    ROB_IDX [N:0]   rob_idxs_n;
        // To: dispatch
        // rob idxs of entries that can be allocated this cycle
} rob2dispatch;

typedef struct packed {
    `CNT_TYPE(N)        vld_scnt;
        // From: retire (ROB)
        // - number of valid retire lines

`ifndef SYNTH
    PHYS_REG_IDX[N-1:0] tag;
    REG_IDX     [N-1:0] dst;
`endif
    logic       [N-1:0] cpl;
    PHYS_REG_IDX[N-1:0] t_old;

    FU_IDX      [N-1:0] fu_idx;
    logic       [N-1:0] halt;
    logic       [N-1:0] illegal;
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
} rob2retire;


// ================
// Owner: RS
// ================
// Packets: RS
typedef struct packed {
    logic bypass1;
    logic bypass2;
    `IDX_TYPE(N) cdb_idx1;
    `IDX_TYPE(N) cdb_idx2;
} BYPASS_TAG;

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

// I/O: RS
typedef struct packed {
    logic   [FU_IDX_NUM-1:0][N-1:0] rdy_sbus;
        // - From: RS
} rs2dispatch;

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


// ================
// Owner: Execute
// ================
// Packets: Execute
// I/O: Execute
typedef struct packed {
    logic   [NUM_FU_ALU-1:0]    fu_rdy_alu;
    logic   [NUM_FU_MUL-1:0]    fu_rdy_mul;
    logic   [NUM_FU_STR-1:0]    fu_rdy_str;
    logic   [NUM_FU_LOD-1:0]    fu_rdy_lod;
    logic   [NUM_FU_BRU-1:0]    fu_rdy_bru;

    logic   [NUM_FU_ALU-1:0]    fu_cdb_gnt_alu; // 1-cycle insns need to win CDB arb. to issue
    logic   [NUM_FU_BRU-1:0]    fu_cdb_gnt_bru; // 1-cycle insns need to win CDB arb. to issue
} execute2rs;

typedef struct packed {
    // for reading
    BTQ_IDX [NUM_FU_BRU-1:0] btq_ridx;
} execute2btq;

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

// tag completion bus (i.e. early wakeup bus)
typedef struct packed {
    logic           [N-1:0] en;
    PHYS_REG_IDX    [N-1:0] ts;
} execute2complete_tag;

// data completion bus (i.e. CDB)
typedef struct packed {
    logic           [N-1:0] en;
    PHYS_REG_IDX    [N-1:0] ts;
        // - From: EX
    ROB_IDX         [N-1:0] rob_idxs;
        // - From: EX
    DATA            [N-1:0] data;
} execute2complete_dat;

// branch completion bus
typedef struct packed {
    // resolution
    logic   [NUM_FU_BRU-1:0] en;
    logic   [NUM_FU_BRU-1:0] take;
    WADDR   [NUM_FU_BRU-1:0] tgt;
    BTQ_IDX [NUM_FU_BRU-1:0] btq_idx;
    logic   [NUM_FU_BRU-1:0] ghr_vld;   // was the branch shifted into the GHR at all?
    GHR_IDX [NUM_FU_BRU-1:0] ghr_base;

    BMASK       clmsk; // OR of all b1hots of resolving branches

    // misprediction
    logic       flush;
    WADDR       flush_fb_base;
    logic[3:0]  flush_fb_off;
        /* Invariants:
        - if flush is high, only en[0] should be high (by convention, we shall
        store the metadata of the mispredicted branch in index 0 of the above arrays)
        - the number of set bits in clmsk should equal the number of set bits in en */
} execute2complete_bru;


// ================
// Owner: Retire
// ================
// Packets: Retire
/**
 * Commit Packet:
 * This is an output of the processor and used in the testbench for counting
 * committed instructions
 *
 * It also acts as a "WB_PKT", and can be reused in the final project with
 * some slight changes
 */
typedef struct packed {
    `CNT_TYPE(N)    wen_cnt;
    logic   [N-1:0] halt;
    logic   [N-1:0] illegal;
} COMMIT_PKT;

// I/O: Retire
typedef struct packed {
    `CNT_TYPE(N)            en_cnt;
    PHYS_REG_IDX [N-1:0]    t_old;
    logic        [N-1:0]    halt;
    logic        [N-1:0]    illegal;
} RETIRE_PKT;


// ================
// Only-owned I/Os
// ================
typedef struct packed {
    `CNT_TYPE(N)    snap_rdy_scnt;
    BMASK [N-1:0]   b1hot_n;
    BMASK [N:0]     bmask_n;
} bman2rename;

typedef struct packed {
    PHYS_REG_IDX [N-1:0] t1s;
    PHYS_REG_IDX [N-1:0] t2s;
    PHYS_REG_IDX [N-1:0] ts_old;
} map_table2dispatch;

typedef struct packed {
    `CNT_TYPE(N) vld_scnt;
        // From: Free list
        // - sat. count of number of free pregs in free list;
        //   count reflects any pregs returned in retire! (i.e. AFTER retires)
    PHYS_REG_IDX [N-1:0] ts;
        // From: Free list
        // - newly allocated pregs

    logic [N:0][`IDX_SIZE(ROB_SZ)-1:0] fl_heads_n;
} free_list2dispatch;

typedef struct packed{
    `BY_FU(DATA)    v1s;
    `BY_FU(DATA)    v2s;
} prf2execute;

`ifdef DEBUG
`include "debug.svh"
`endif

`endif // __SYS_DEFS_SVH__
