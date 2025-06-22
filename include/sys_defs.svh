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

// all files should `include "sys_defs.svh" to at least define the timescale
`timescale 1ns/100ps

// helpful macros
`define MIN(a, b) ((a) < (b) ? (a) : (b))
`define MAX(a, b) ((a) > (b) ? (a) : (b))

`define CNT_TYPE(max) logic [$clog2(max+1)-1:0] // smallest bit-vector to store max
`define CNT_SIZE(max) ($clog2(max+1))           // ...and number of bits in that type

`define IDX_TYPE(len) logic [$clog2(len)-1:0]   // smallest bit-vector to index an array of length len
`define IDX_SIZE(len) ($clog2(len))             // ...and number of bits in that type

`define UCAST_LEN(n, max) ($clog2(max+1)'(unsigned'(n)))
`define UCAST_FIT(n) (($clog2(n+1))'(unsigned'(n)))    // cast fit unsigned

///////////////////////////////
// --- Compil. Controls ---- //
///////////////////////////////
/* How can we implement this in the Makefile? */
// `define SYNTH // synth only constructions

`ifndef SYNTH
// `define DEBUG
// `define CYCLE_PRINT // clock cycle print
// `define PC_GEN_TEST_MODE
`endif

/* Memory config */
// Cache mode removes the byte-level interface from memory, so it always returns
// a double word. The original processor won't work with this defined. Your new
// processor will have to account for this effect on mem.
// Notably, you can no longer write data without first reading.
// TODO: uncomment this line once you've implemented your cache
`define CACHE_MODE


/* Constants */
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
typedef logic [3:0] MEM_TAG;

`define MEM_SIZE_IN_BYTES (64*1024)
`define MEM_64BIT_LINES   (`MEM_SIZE_IN_BYTES/8)


///////////////////////////////////
// ---- Starting Parameters ---- //
///////////////////////////////////

// some starting parameters that you should set
// this is *your* processor, you decide these values (try analyzing which is best!)

// superscalar width
parameter N = 2;
// parameter CDB_SZ= N // This MUST match your superscalar width

// sizes
parameter ROB_SZ= 64;
parameter BTQ_SZ= 16;
    /* BTQ_SZ doubled (form 8). This improved CPI on tight loop
    programs like branchy.s and branchy_nested.s */
parameter RAS_SZ= 16;
parameter FTQ_SZ= 32;
parameter PHYS_REG_SZ_P6    = 32;
parameter PHYS_REG_SZ_R10K  = (32 + ROB_SZ);

parameter IQQ_SZ= 4;
parameter IRQ_SZ= 8;
parameter DCACHE_LINES = 32;

// worry about these later
parameter BRANCH_PRED_SZ= 'x;
parameter LSQ_SZ        = 12;
parameter SQ_RET_BUF_SZ = 4;
parameter GHR_BUF_SZ    = 32;
parameter GHR_LEN       = 8;
parameter BMASK_LEN     = 8; // i.e. number of branch checkpoints

// functional units (you should decide if you want more or fewer types of FUs)
parameter NUM_FU_ALU    = 2;
parameter NUM_FU_MUL    = 1;
parameter NUM_FU_LOD    = 1;
parameter NUM_FU_STR    = 1;
parameter NUM_FU_BRU    = 1;
parameter NUM_FU_TOTAL  = NUM_FU_ALU + NUM_FU_MUL + NUM_FU_LOD + NUM_FU_STR + NUM_FU_BRU;

parameter LD_BAY_SZ     = 2; //num load bays in the FU

// number of mult stages (2, 4) (you likely don't need 8)
parameter MUL_STAGES    = 16;
// Justin: funny enough we need at least 8 or else multiply is on critical path


/* Types */
// word and register sizes
typedef logic [31:0] DATA;
typedef logic [4:0]  REG_IDX;

typedef logic [31:0] ADDR;
typedef logic [15:0] BADDR;
typedef logic [14:0] HADDR;
typedef logic [13:0] WADDR;
typedef logic [12:0] DWADDR;

typedef logic [BMASK_LEN-1:0] BMASK;

// Double word address (restricted to only used 16 LSB)
function automatic DWADDR addr2dw(input ADDR addr);
    return addr[15:3];
endfunction
function automatic ADDR dw2addr(input DWADDR addr);
    return {16'b0, addr, 3'b0};
endfunction

// Word address
function automatic WADDR addr2w(input ADDR addr);
    return addr[15:2];
endfunction
function automatic ADDR w2addr(input WADDR addr);
    return {16'b0, addr, 2'b0};
endfunction

// In-word byte offset
function automatic logic[1:0] iw_off(input ADDR addr);
    return addr[1:0];
endfunction

// In-double-word byte offset
function automatic logic[2:0] idw_off(input ADDR addr);
    return addr[2:0];
endfunction

parameter int FU_IDX_NUM = 5;
typedef enum logic [2:0] {
    FU_ALU  = 'd0,
    FU_MUL = 'd1,
    FU_LOD = 'd2,
    FU_STR  = 'd3,
    FU_BRU  = 'd4
} FU_IDX;

typedef `IDX_TYPE(BTQ_SZ) BTQ_IDX;
typedef `IDX_TYPE(ROB_SZ) ROB_IDX;
typedef `IDX_TYPE(LSQ_SZ) LSQ_IDX;

// A memory or cache block
typedef union packed {
    logic [7:0][7:0]  byte_level;
    logic [3:0][15:0] half_level;
    logic [1:0][31:0] word_level;
    logic      [63:0] dbbl_level;
} MEM_BLOCK;
typedef union packed {
    logic [3:0][7:0]  byte_level;
    logic [1:0][15:0] half_level;
    logic      [31:0] word_level;
} DATA_BLOCK;

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



///////////////////////////////
// ---- Basic Constants ---- //
///////////////////////////////

// NOTE: the global CLOCK_PERIOD is defined in the Makefile

// useful boolean single-bit definitions
`define FALSE 1'h0
`define TRUE  1'h1

/* 
NEED CLARIFICATION:
NOTE: We will use PHYS_REG_IDX = 0 as a sentinel (to denote "no register" / "is immediate operand").
While we lose out on a single physical register, this greatly simplifies logic 
(the alternative is to pipe around 'is valid src_reg' bit signals everywhere).
*/
typedef `IDX_TYPE(PHYS_REG_SZ_R10K) PHYS_REG_IDX;

// the zero register
// In RISC-V, any read of this register returns zero and any writes are thrown away
`define ZERO_REG 5'd0

// Basic NOP instruction. Allows pipline registers to clearly be reset with
// an instruction that does nothing instead of Zero which is really an ADDI x0, x0, 0
`define NOP 32'h00000013


///////////////////////////////////
// ---- Instruction Typedef ---- //
///////////////////////////////////

// from the RISC-V ISA spec
typedef union packed {
    logic [31:0] inst;
    struct packed {
        logic [6:0] funct7;
        logic [4:0] rs2; // source register 2
        logic [4:0] rs1; // source register 1
        logic [2:0] funct3;
        logic [4:0] rd; // destination register
        logic [6:0] opcode;
    } r; // register-to-register instructions
    struct packed {
        logic [11:0] imm; // immediate value for calculating address
        logic [4:0]  rs1; // source register 1 (used as address base)
        logic [2:0]  funct3;
        logic [4:0]  rd;  // destination register
        logic [6:0]  opcode;
    } i; // immediate or load instructions
    struct packed {
        logic [6:0] off; // offset[11:5] for calculating address
        logic [4:0] rs2; // source register 2
        logic [4:0] rs1; // source register 1 (used as address base)
        logic [2:0] funct3;
        logic [4:0] set; // offset[4:0] for calculating address
        logic [6:0] opcode;
    } s; // store instructions
    struct packed {
        logic       of;  // offset[12]
        logic [5:0] s;   // offset[10:5]
        logic [4:0] rs2; // source register 2
        logic [4:0] rs1; // source register 1
        logic [2:0] funct3;
        logic [3:0] et;  // offset[4:1]
        logic       f;   // offset[11]
        logic [6:0] opcode;
    } b; // branch instructions
    struct packed {
        logic [19:0] imm; // immediate value
        logic [4:0]  rd; // destination register
        logic [6:0]  opcode;
    } u; // upper-immediate instructions
    struct packed {
        logic       of; // offset[20]
        logic [9:0] et; // offset[10:1]
        logic       s;  // offset[11]
        logic [7:0] f;  // offset[19:12]
        logic [4:0] rd; // destination register
        logic [6:0] opcode;
    } j;  // jump instructions

// extensions for other instruction types
`ifdef ATOMIC_EXT
    struct packed {
        logic [4:0] funct5;
        logic       aq;
        logic       rl;
        logic [4:0] rs2;
        logic [4:0] rs1;
        logic [2:0] funct3;
        logic [4:0] rd;
        logic [6:0] opcode;
    } a; // atomic instructions
`endif
`ifdef SYSTEM_EXT
    struct packed {
        logic [11:0] csr;
        logic [4:0]  rs1;
        logic [2:0]  funct3;
        logic [4:0]  rd;
        logic [6:0]  opcode;
    } sys; // system call instructions
`endif

} INST; // instruction typedef, this should cover all types of instructions


////////////////////////////////////////
// ---- Datapath Control Signals ---- //
////////////////////////////////////////

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

typedef enum logic [0:1] {
    FIFO_FLUSH_RESET     = 0, // default
    FIFO_FLUSH_SNAP_HEAD = 1, // wind head to checkpoint
    FIFO_FLUSH_SNAP_TAIL = 2  // wind tail to checkpoint
} FIFO_FLUSH_MODE;

typedef enum logic [0:1] {
    SKID_FLUSH_RESET  = 0,
    SKID_FLUSH_MASK   = 1,
    SKID_FLUSH_IGNORE = 2
} SKID_FLUSH_MODE;


////////////////////////////////
// ---- Datapath Packets ---- //
////////////////////////////////

/**
 * Packets are used to move many variables between modules with
 * just one datatype, but can be cumbersome in some circumstances.
 *
 * Define new ones in project 4 at your own discretion
 */

typedef struct packed {
    logic [N-1:0][`IDX_SIZE(RAS_SZ)-1:0] top;
    logic [N-1:0][`CNT_SIZE(RAS_SZ)-1:0] used;
} RAS_SNAP;

// BPU stuff
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

            Maybe lo4 for fallthrough (end_off), off for branch pc_off?
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
    logic [3:0] pc_off; // pc = base + pc_off
    logic       take;
    WADDR       tgt;

    FTB_MD1 md;
} FTB_UPD_PKT;

typedef struct packed {
`ifdef PC_GEN_TEST_MODE
    int id;
`endif
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
    DWADDR          dw;
    logic[1:0][3:0] off;
    logic   [1:0]   fmsk;   // which words to fetch.
        /* Invariants:
        1. At least bit 0 (word 0) set
        2. Bits set contiguously from 0

        FUTURE: Invariant 2 may no longer hold if we detect when a branch in an
        early word targets into a later word *in the same cache line*,
        AND we allow storing them together in a single cache line. Then and all insns
        between the branch and target would have fmsk set to 0.
            Idea: if the branch target is in the same cache line as the
            branch (much more likely with larger cache lines), we may reuse
            the 14-bit tgt field in the FTB branch slot as a [$clog2(cache_line_sz)-1:0]
            in-line offset (possible with a carry bit for faster computation).
        */
    logic   [1:0]   is_end;
        /* Does word i *terminate* an FB?
        Both bits can be 1 when word0 ends FB-A and word1 ends FB-B (a 1-insn block). */
    
    MEM_BLOCK       blk;
    BRANCH_MD[1:0]  md;

} ICACHE_RESPONSE;



// BTQ stuff
typedef struct packed {
    // FTB_UPD_PKT fields
    WADDR       base;
    logic [3:0] pc_off; // pc = base + pc_off
    logic       take;
    WADDR       tgt;

    logic       always_take; // i.e. a cond branch that is always taken?
    FTB_MD1     md;

    // predictor-specific fields
    logic en_dir_update;    // update direction predictors?
    logic [GHR_LEN-1:0] hash; // gshare hash

} BPU_UPD_PKT;

typedef struct packed {
    logic en;
    WADDR pc;
    WADDR tgt;
} puq2btb;

typedef struct packed {
    DWADDR              dw;
    logic   [1:0][3:0]  off;
        // FB_OFF[1:0][1:0]ixq_out_off,
    logic   [1:0]       fmsk;
    logic   [1:0]       is_end;
} pc_gen2ixq;



/* i/o structs */
/**
 * IF_ID Packet:
 * Data exchanged from the IF to the ID stage
 */
typedef struct packed {
    INST  inst;
    WADDR PC;

    RAS_SNAP ras_snap;
    BTQ_IDX btq_idx;
} IF_ID_PACKET;


typedef struct packed {
    logic       en;
    BPU_UPD_PKT dat;
} puq2fetch;

typedef struct packed {
    `CNT_TYPE(N) btq_rdy_scnt;
    BTQ_IDX [N-1:0]        btq_idxs_n;

    puq2fetch   bp_upd;
} btq2fetch;


typedef struct packed {
    `CNT_TYPE(N)           en_cnt;
        // How many branch instructions dispatching?
        // Sender must ensure branch insns packed to lowest indices.
    logic   [N-1:0]        is_tail;
    WADDR   [N-1:0]        PC;
    logic   [N-1:0][3:0]   off;
    logic   [N-1:0]        pred;
    WADDR   [N-1:0]        pred_tgt;
    logic   [N-1:0]        always_take;
    FTB_MD1 [N-1:0]        md;

    logic   [N-1:0]        hit;
    logic   [N-1:0]        hit_slot;
    logic   [N-1:0][GHR_LEN-1:0] hash; // gshare hash index
    logic   [N-1:0][`IDX_SIZE(GHR_BUF_SZ)-1:0] ghr_base;
} fetch2btq;




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
