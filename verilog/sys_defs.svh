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

///////////////////////////////////
// ---- Starting Parameters ---- //
///////////////////////////////////

// some starting parameters that you should set
// this is *your* processor, you decide these values (try analyzing which is best!)

// superscalar width
`define N 2
`define CDB_SZ `N // This MUST match your superscalar width

// sizes
`define ROB_SZ 64
`define RS_SZ  16
`define BTQ_SZ 8
`define PHYS_REG_SZ_P6 32
`define PHYS_REG_SZ_R10K (32 + `ROB_SZ)

// worry about these later
`define BRANCH_PRED_SZ xx
`define LSQ_SZ 8
`define LSQ_SZ_DBL 16
`define SQ_RET_BUF_SZ 4

// functional units (you should decide if you want more or fewer types of FUs)
`define NUM_FU_ALU 2
`define NUM_FU_MULT 1
`define NUM_FU_LOAD 1
`define LD_BAY_SZ 4 //num load bays in the FU
`define NUM_FU_STORE 1
// `define NUM_FU_TOTAL `NUM_FU_ALU + `NUM_FU_MULT + `NUM_FU_LOAD + `NUM_FU_STORE
`define NUM_FU_TOTAL `NUM_FU_ALU + `NUM_FU_MULT + `NUM_FU_LOAD + `NUM_FU_STORE

// number of mult stages (2, 4) (you likely don't need 8)
`define MULT_STAGES 16
// Justin: funny enough we need at least 8 or else multiply is on critical path


`define BTB_ENTRIES 256
`define BTB_TAG_WIDTH 12

`define PREFETCH_CAP 24 // <- how far ahead we can prefetch

///////////////////////////////
// --- Compil. Controls ---- //
///////////////////////////////
/* How can we implement this in the Makefile? */
// comment out to enable synth only constructions
// `define SYNTH

`ifndef SYNTH
// comment out to disable DEBUG:
`define DEBUG
`endif

///////////////////////////////
// ---- Basic Constants ---- //
///////////////////////////////

// NOTE: the global CLOCK_PERIOD is defined in the Makefile

// useful boolean single-bit definitions
`define FALSE 1'h0
`define TRUE  1'h1

// word and register sizes
typedef logic [31:0] ADDR;
typedef logic [31:0] DATA;
typedef logic [4:0] REG_IDX;

/* 
NEED CLARIFICATION:
NOTE: We will use PHYS_REG_IDX = 0 as a sentinel (to denote "no register" / "is immediate operand").
While we lose out on a single physical register, this greatly simplifies logic 
(the alternative is to pipe around 'is valid src_reg' bit signals everywhere).
*/
typedef logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] PHYS_REG_IDX;

// the zero register
// In RISC-V, any read of this register returns zero and any writes are thrown away
`define ZERO_REG 5'd0

// Basic NOP instruction. Allows pipline registers to clearly be reset with
// an instruction that does nothing instead of Zero which is really an ADDI x0, x0, 0
`define NOP 32'h00000013

//////////////////////////////////
// ---- Memory Definitions ---- //
//////////////////////////////////

// Cache mode removes the byte-level interface from memory, so it always returns
// a double word. The original processor won't work with this defined. Your new
// processor will have to account for this effect on mem.
// Notably, you can no longer write data without first reading.
// TODO: uncomment this line once you've implemented your cache
// `define CACHE_MODE

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

// icache definitions
`define ICACHE_LINES 32
`define ICACHE_LINE_BITS $clog2(`ICACHE_LINES)

`define MEM_SIZE_IN_BYTES (64*1024)
`define MEM_64BIT_LINES   (`MEM_SIZE_IN_BYTES/8)

// A memory or cache block
typedef union packed {
    logic [7:0][7:0]  byte_level;
    logic [3:0][15:0] half_level;
    logic [1:0][31:0] word_level;
    logic      [63:0] dbbl_level;
} MEM_BLOCK;

typedef enum logic [1:0] {
    BYTE   = 2'h0,
    HALF   = 2'h1,
    WORD   = 2'h2,
    DOUBLE = 2'h3
} MEM_SIZE;

// Memory bus commands
typedef enum logic [1:0] {
    MEM_NONE   = 2'h0,
    MEM_LOAD   = 2'h1,
    MEM_STORE  = 2'h2
} MEM_COMMAND;

// icache tag struct
typedef struct packed {
    logic [12-`ICACHE_LINE_BITS:0] tags;
    logic                          valid;
} ICACHE_TAG;

///////////////////////////////
// ---- Exception Codes ---- //
///////////////////////////////

/**
 * Exception codes for when something goes wrong in the processor.
 * Note that we use HALTED_ON_WFI to signify the end of computation.
 * It's original meaning is to 'Wait For an Interrupt', but we generally
 * ignore interrupts in 470
 *
 * This mostly follows the RISC-V Privileged spec
 * except a few add-ons for our infrastructure
 * The majority of them won't be used, but it's good to know what they are
 */

typedef enum logic [3:0] {
    INST_ADDR_MISALIGN  = 4'h0,
    INST_ACCESS_FAULT   = 4'h1,
    ILLEGAL_INST        = 4'h2,
    BREAKPOINT          = 4'h3,
    LOAD_ADDR_MISALIGN  = 4'h4,
    LOAD_ACCESS_FAULT   = 4'h5,
    STORE_ADDR_MISALIGN = 4'h6,
    STORE_ACCESS_FAULT  = 4'h7,
    ECALL_U_MODE        = 4'h8,
    ECALL_S_MODE        = 4'h9,
    NO_ERROR            = 4'ha, // a reserved code that we use to signal no errors
    ECALL_M_MODE        = 4'hb,
    INST_PAGE_FAULT     = 4'hc,
    LOAD_PAGE_FAULT     = 4'hd,
    HALTED_ON_WFI       = 4'he, // 'Wait For Interrupt'. In 470, signifies the end of computation
    STORE_PAGE_FAULT    = 4'hf
} EXCEPTION_CODE;

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
} MULT_FUNC;

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
 * IF_ID Packet:
 * Data exchanged from the IF to the ID stage
 */
typedef struct packed {
    INST  inst;
    ADDR  PC;
    ADDR  NPC; // PC + 4
    logic valid;
} IF_ID_PACKET;

/**
 * ID_EX Packet:
 * Data exchanged from the ID to the EX stage
 */
typedef struct packed {
    INST inst;
    ADDR PC;
    ADDR NPC; // PC + 4

    DATA rs1_value; // reg A value
    DATA rs2_value; // reg B value

    ALU_OPA_SELECT opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    REG_IDX  dest_reg_idx;  // destination (writeback) register index
    ALU_FUNC alu_func;      // ALU function select (ALU_xxx *)
    logic    mult;          // Is inst a multiply instruction?
    logic    rd_mem;        // Does inst read memory?
    logic    wr_mem;        // Does inst write memory?
    logic    cond_branch;   // Is inst a conditional branch?
    logic    uncond_branch; // Is inst an unconditional branch?
    logic    halt;          // Is this a halt?
    logic    illegal;       // Is this instruction illegal?
    logic    csr_op;        // Is this a CSR operation? (we only used this as a cheap way to get return code)

    logic    valid;
} ID_EX_PACKET;

/**
 * EX_MEM Packet:
 * Data exchanged from the EX to the MEM stage
 */
typedef struct packed {
    DATA alu_result;
    ADDR NPC;

    logic    take_branch; // Is this a taken branch?
    // Pass-through from decode stage
    DATA     rs2_value;
    logic    rd_mem;
    logic    wr_mem;
    REG_IDX  dest_reg_idx;
    logic    halt;
    logic    illegal;
    logic    csr_op;
    logic    rd_unsigned; // Whether proc2Dmem_data is signed or unsigned
    MEM_SIZE mem_size;
    logic    valid;
} EX_MEM_PACKET;

/**
 * MEM_WB Packet:
 * Data exchanged from the MEM to the WB stage
 *
 * Does not include data sent from the MEM stage to memory
 */
typedef struct packed {
    DATA    result;
    ADDR    NPC;
    REG_IDX dest_reg_idx; // writeback destination (ZERO_REG if no writeback)
    logic   take_branch;
    logic   halt;    // not used by wb stage
    logic   illegal; // not used by wb stage
    logic   valid;
} MEM_WB_PACKET;

/**
 * Commit Packet:
 * This is an output of the processor and used in the testbench for counting
 * committed instructions
 *
 * It also acts as a "WB_PACKET", and can be reused in the final project with
 * some slight changes
 */
typedef struct packed {
    // ADDR    NPC;
    // DATA    data;
    // REG_IDX reg_idx;
    logic   halt;
    logic   illegal;
    logic   valid;
} COMMIT_PACKET;

// ROB stuff
typedef logic [$clog2(`ROB_SZ)-1:0] ROB_IDX;
typedef struct packed {
    logic cpl;
    logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] tag;
    logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] t_old;
    REG_IDX dst;
    
    logic is_brch;
    logic wr_mem;
    logic rd_mem;
    logic halt;
    logic illegal;
} ROB_ENTRY;

//allowing one bit greater than strictly necessary 
//so that we can use values above what we will see 
//in the LSQ as the initial value for SQ_IDX in 
//dispatch if a load comes before the first store
typedef logic [$clog2(`LSQ_SZ_DBL):0] LSQ_IDX; 
typedef struct packed {
    LSQ_IDX sq_idx;
    ROB_IDX rob_idx;
    ADDR addr;
    logic [3:0] bytewise_addr_mask;
    DATA data;
    logic d_vld;
    MEM_SIZE mem_size; //MEM_SIZE'(id_ex_reg.inst.r.funct3[1:0]); <-- HOW TO FIND THIS. DO THIS WHEN PUTTING ENTRY IN FROM DISPATCH OR FROM EXECUTE
} SQ_ENTRY;

typedef struct packed {
    LSQ_IDX sq_idx;
    ADDR addr;
    logic d_vld;
    MEM_SIZE mem_size;
    ADDR inst_pc;
    logic err_ld_ooo;
} LQ_ENTRY;

// BTQ stuff
// By btq
typedef logic [$clog2(`BTQ_SZ)-1:0] BTQ_IDX;
typedef struct packed {
    ADDR    tgt;   // can we actually store [29:0], since bottom bits of address are 0s anyways?
    ADDR    NPC;   // PC + 4 (i.e. address if we dont take the branch)
    logic   pred;
    logic   take;
} BTQ_ENTRY;

typedef struct packed {
    logic   [$clog2(`N):0]  btq_rdy_scnt;
    BTQ_IDX [`N-1:0]        btq_idxs;
} btq2dispatch;

typedef struct packed {
    logic   [$clog2(`N):0]  used_scnt; // FIXME: This is actually unused?
    BTQ_ENTRY [`N-1:0]      dat;
} btq2retire;

typedef struct packed {
    logic   [$clog2(`N):0]  rd_cnt;
} retire2btq;

typedef struct packed {
    logic [$clog2(`N):0]        r_en_cnt; // final final
    PHYS_REG_IDX [`N-1:0]       tag;
    PHYS_REG_IDX [`N-1:0]       t_old;
    REG_IDX      [`N-1:0]       dst;
    logic        [`N-1:0]       halt;
    logic        [`N-1:0]       illegal;
    logic        [`N-1:0]       is_brch;
} retire_final;

typedef struct packed {
    ADDR    corrected_PC;
} retire2fetch;

typedef struct packed {
    /* Alloc */
    /* Rename */
    /* Commit */
    logic   [$clog2(`N):0] en_cnt;
        // How many branch instructions dispatching?
        // Sender must ensure branch insns packed to lowest indices.
    ADDR    [`N-1:0]       NPC;
} dispatch2btq;

// Reservation station stuff
typedef enum logic [1:0] {
    FU_ALU  = 2'b00,
    FU_MULT = 2'b01,
    FU_LOAD = 2'b10,
    FU_STORE = 2'b11
} FU_IDX;
`define FU_IDX_NUM 4

typedef struct packed {
    int             id; // debug only; unique insn identifier

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy; // completed? should we rename to cpl for consistency?
    logic           t2_rdy;
    FU_IDX          fu_idx;
    ROB_IDX         rob_idx;
    BTQ_IDX         btq_idx;
    LSQ_IDX         sq_idx;
    LSQ_IDX         lq_idx; //THESE ARE TWO DIFFERENT THINGS, BOTH REQUIRED. DO *NOT* COMBINE THEM
    logic           is_brch; // Is inst a branch?
    

    /* from ID_EX_PACKET */
    INST inst;
    ADDR PC;
    ADDR NPC; // PC + 4

    ALU_OPA_SELECT opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    REG_IDX  dest_reg_idx;  // destination (writeback) register index
    ALU_FUNC alu_func;      // ALU function select (ALU_xxx *)
    logic    mult;          // Is inst a multiply instruction?
    logic    rd_mem;        // Does inst read memory?
    logic    wr_mem;        // Does inst write memory?
    logic    cond_branch;   // Is inst a conditional branch?
    logic    uncond_branch; // Is inst an unconditional branch?
    logic    halt;          // Is this a halt?
    logic    illegal;       // Is this instruction illegal?
    logic    csr_op;        // Is this a CSR operation? (we only used this as a cheap way to get return code)

    // logic    valid;
} ID_RESULT;

typedef struct packed {
    /* ETB bypass control */
    logic bypass1;  // set iff 1) awaken by a complete to its src1 AND 2) issued same cycle
        /* Q: How to implement?
        A: Set if a complete readies our src1. Clear if we do not issue same cycle.
        If an insn issues 1 or more cycles *after* all of its source operands
        have been readied, then they will be ready in the PRF, and thus bypass
        is needed. */
    logic bypass2;

    /* This is a ridiculous optimization. Try impl a simple CAM first. */
    logic [$clog2(`N)-1:0]  cdb_idx1;   // which cdb slot to bypass for src1 (valid iff bypass1 set)
    logic [$clog2(`N)-1:0]  cdb_idx2;
} BYPASS_TAG;

typedef struct packed {
    logic           busy;
    logic           issued;
    ID_RESULT       dat;
} RS_ENTRY;

// By Fetch
typedef struct packed {
    logic       [$clog2(`N):0]  f_en_cnt;
    IF_ID_PACKET    [`N-1:0]    f_dat;
} fetch2decode;

typedef struct packed {
    MEM_COMMAND proc2mem_command;
    ADDR        proc2mem_addr;
} fetch2mem;

// By decode
typedef struct packed {
    logic       [$clog2(`N):0]  d_rdy_cnt;
} decode2fetch;

typedef struct packed {
    logic       [$clog2(`N):0]  d_vld_scnt;
    logic       [`N-1:0]  prvw_has_dests;
    logic       [`N-1:0]  prvw_is_brch;
    ID_RESULT   [`N-1:0]        d_dat;
} decode2dispatch;

// By Dispatch
typedef struct packed {
    // NOTE: This is the only place where a transaction is
    // RECIEVER-decided!!! (i.e. receiver broadcasts enable signals)
    logic       [$clog2(`N):0]  dispatch_en_cnt;
} dispatch2decode;

typedef struct packed {
    /* Alloc */
    /* Rename */
    /* Commit */
    logic       [$clog2(`N):0] d_en_cnt;
        // - To: RS
        // - Number of enabled dispatch lines? (replacement for d_vld)
        // - Question: permit
        // 1) only N dispatches, OR
        // 2) a different limit number of dispatches DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
        // (DIS_MAX will be a new sys_defs.svh constant) ?
    ID_RESULT   [`N-1:0] d_dat; //shouldn't have dispatch feed to RS,
        // - To: RS               //should come directly from dispatch
} dispatch2rs;

typedef struct packed {
    /* Alloc */
    logic   [$clog2(`N):0]  alloc_en_cnt;
    /* Rename */
    /* Commit */
    logic   [$clog2(`N):0]  d_en_cnt;
        // To: ROB
        // - Number of enabled dispatch lines?
    logic [`N-1:0][$clog2(`PHYS_REG_SZ_R10K)-1:0] tag;
    logic [`N-1:0][$clog2(`PHYS_REG_SZ_R10K)-1:0] t_old;
        // From: dispatch
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    //THESE ARE NOT COMING FROM DISPATCH, GET THESE FROM MAP TABLE
    //(ONLY HERE FOR CURRENT ROB TESTBENCH)
    REG_IDX [`N-1:0] dst;
    logic [`N-1:0] is_brch;
    logic [`N-1:0] wr_mem;
    logic [`N-1:0] rd_mem;
    logic [`N-1:0] halt;
    logic [`N-1:0] illegal;
} dispatch2rob;

typedef struct packed {
    logic     [$clog2(`N):0]  free_d_en_cnt;
        // To: Free list
        // - number of enabled dispatch lines WHO NEED A DEST PREG 
        //   (e.g. no stores)
        //   (i.e. may only be a strict subset of dispatching insns!)
} dispatch2free_list;

typedef struct packed {
    // alloc
    // rename
    logic   [$clog2(`N):0]  rename_en_cnt;
    // commit
    logic   [$clog2(`N):0]  sq_d_en_cnt;
        // To: LSQ
        // - number of enabled dispatch lines WHO NEED A LD/ST 
        //   (i.e. may only be a strict subset of dispatching insns!)
    ROB_IDX [`N-1:0] rob_idx;
} dispatch2sq;

typedef struct packed {
    // alloc
    // rename 
    logic   [$clog2(`N):0]  rename_en_cnt;
    // commit
    logic   [$clog2(`N):0]  lq_d_en_cnt;
        // To: LSQ
        // - number of enabled dispatch lines WHO NEED A LD/ST 
        //   (i.e. may only be a strict subset of dispatching insns!)
    ROB_IDX [`N-1:0] rob_idx;
    LSQ_IDX [`N-1:0] sq_idx;
    ADDR    [`N-1:0] inst_pc;
} dispatch2lq;

typedef struct packed {
    logic         [$clog2(`N):0] en_cnt;
        // - Number of enabled dispatch lines?
        // - NOTE: For in-order stuff with serial deps (like dispatch), use c(ou)nts;
        // otherwise use en(able) buses.
    REG_IDX       [`N-1:0] src1s;
    REG_IDX       [`N-1:0] src2s;
    REG_IDX       [`N-1:0] dsts;
    PHYS_REG_IDX  [`N-1:0] ts;
        // To: Map table
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    // THIS WILL BE 1 CLOCK CYCLE BEHIND. THIS IS DESIRED SO THAT
    // TAGS ARE APPLIED AT THE CORRECT TIMES (paired with free list tag output)
    // (means that tags will be applied when the dispatched insts actually get
    // to RS/ROB)
} dispatch2map_table;


// By Map Table

typedef struct packed {
    logic        [`N-1:0] cpl1s;
    logic        [`N-1:0] cpl2s;
    PHYS_REG_IDX [`N-1:0] t1s;
    PHYS_REG_IDX [`N-1:0] t2s;
    PHYS_REG_IDX [`N-1:0] ts_old;
} map_table2dispatch;


// By RS
typedef struct packed {
    logic       [$clog2(`N):0] rs_rdy_scnt;
        // - From: RS
} rs2dispatch;

typedef struct packed {
    /* Requested by issue arbiter 
    (only ALU needs gnt by CDB arbiter to 'en')*/
    logic       [`NUM_FU_ALU-1:0]    fu_vld_alu;

    /* Selected for issue */
    logic       [`NUM_FU_ALU-1:0]    fu_en_alu;
    logic       [`NUM_FU_MULT-1:0]   fu_en_mult;
    logic       [`NUM_FU_STORE-1:0]  fu_en_store;
    logic       [`NUM_FU_LOAD-1:0]   fu_en_load;

    BYPASS_TAG  [`NUM_FU_ALU-1:0]    bytag_alu;
    BYPASS_TAG  [`NUM_FU_MULT-1:0]   bytag_mul;
    BYPASS_TAG  [`NUM_FU_LOAD-1:0]   bytag_ldr;
    BYPASS_TAG  [`NUM_FU_STORE-1:0]  bytag_str;

    ID_RESULT   [`NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT   [`NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT   [`NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT   [`NUM_FU_LOAD-1:0]   fu_dat_load;
} rs2execute;

// By ROB
typedef struct packed {
    logic    [$clog2(`N):0]     rob_rdy_scnt;
        // From: ROB
        // saturating counter for number of free rob entries
    ROB_IDX [`N-1:0]            rob_idxs; //not needed, but putting here for testbench
        // To: dispatch
        // rob idxs of entries that can be allocated this cycle
        // Option 1: This
        // Option 2: expose HEAD pointer and let dispatcher generate these
        // (main concern with option 2 is it could be wrong? idk)
} rob2dispatch;

typedef struct packed {
    logic       [$clog2(`N):0]  r_vld_cnt;
        // From: retire (ROB)
        // - number of valid retire lines
    ROB_ENTRY   [`N-1:0]        entries; 
        // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
} rob2retire;


// By Execute
typedef struct packed {
    logic       [`NUM_FU_ALU-1:0]    fu_rdy_alu;
    logic       [`NUM_FU_MULT-1:0]   fu_rdy_mult;
    logic       [`NUM_FU_STORE-1:0]  fu_rdy_store;
    logic       [`NUM_FU_LOAD-1:0]   fu_rdy_load;

    logic       [`NUM_FU_ALU-1:0]    fu_cdb_gnt_alu; // 1-cycle insns need to win CDB arb. to issue
} execute2rs;

typedef struct packed {
    /* TODO: Better to make this a union, with shared c_en and is_brch
    at the top, and union over non-branch and branch-specific stuff? */
    logic           [`N-1:0] en;
    PHYS_REG_IDX    [`N-1:0] ts;
} execute2complete_tag;

typedef struct packed {
    /* TODO: Better to make this a union, with shared c_en and is_brch
    at the top, and union over non-branch and branch-specific stuff? */
    logic           [`N-1:0] en;
    logic           [`N-1:0] is_brch;
        // - From: EX
    PHYS_REG_IDX    [`N-1:0] ts;
        // - From: EX
    ROB_IDX         [`N-1:0] rob_idxs;
        // - From: EX
    DATA            [`N-1:0] data;
        // doubles as branch target if is_brch true

    // BTQ-specific completion stuff
    BTQ_IDX [`N-1:0] btq_idxs; 
        // Entries to which we are completing
    logic   [`N-1:0] take;
} execute2complete_dat;

// By Free List
typedef struct packed {
    logic    [$clog2(`N):0] free_rdy_scnt;
        // From: Free list
        // - sat. count of number of free pregs in free list;
        //   count reflects any pregs returned in retire! (i.e. AFTER retires)
    PHYS_REG_IDX [`N-1:0]   d_ts;
        // From: Free list
        // - newly allocated pregs
        // THIS WILL BE 1 CLOCK CYCLE BEHIND. THIS IS DESIRED SO THAT
        // TAGS ARE APPLIED AT THE CORRECT TIMES (paired with map table output)
        // (means that tags will be applied when the dispatched insts actually get
        // to RS/ROB)
} free_list2dispatch;

typedef struct packed {
    logic [`N-1:0][31:0] PC;
} fetch2btb;

typedef struct packed {
   // ADDR [`N-1:0]  PC,
    logic [`N-1:0] [15:0] target;
    logic [`N-1:0] hit;
} btb2fetch;


typedef struct packed {
    logic [`N-1:0][31:0] PC;
    logic [`N-1:0] is_taken;
    logic [`N-1:0] [15:0] target;
} execute2btb;

typedef struct packed {
    ADDR [`N-1:0] PC;
} fetch2predictor;

typedef struct packed {
    logic [`N-1:0] prediction;
} predictor2fetch;

typedef struct packed {
    logic [`N-1:0] update_enable;
    logic [`N-1:0]taken;
    ADDR [`N-1:0] PC;
} retire2predictor;

// By Arch Map
`define NUM_ARCH_REG 32
typedef struct packed {
    struct packed {
        PHYS_REG_IDX t;
    } [`NUM_ARCH_REG-1:0] state; 
} arch_map2map_table;

`define BY_FU(type) \
struct packed { \
    type [`NUM_FU_ALU-1:0]   alu; \
    type [`NUM_FU_MULT-1:0]  mul; \
    type [`NUM_FU_LOAD-1:0]  lod; \
    type [`NUM_FU_STORE-1:0] str; \
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

// By SQ
typedef struct packed {
    logic   [$clog2(`N):0]  sq_rdy_scnt;
    LSQ_IDX                 last_used_sq_idx;
    LSQ_IDX [`N-1:0]        next_ids;
    logic                   no_store_yet;
} sq2dispatch;

typedef struct packed {
    logic       [`NUM_FU_STORE-1:0] en;
    LSQ_IDX     [`NUM_FU_STORE-1:0] sq_idx_cdb;
} sq2rs;

typedef struct packed {
    logic       [`NUM_FU_STORE-1:0] st_ex_en; //tells SQ that a valid store is coming in on that line (bus, not count)
    LSQ_IDX     [`NUM_FU_STORE-1:0] st_sq_idx; //the SQ IDXs of the incoming stores, found in the ID_RESULT packet
    ADDR        [`NUM_FU_STORE-1:0] st_addr; //address that the stores are pointing to
    DATA        [`NUM_FU_STORE-1:0] st_data; //the data to be stored
    MEM_SIZE    [`NUM_FU_STORE-1:0] st_mem_size; //MEM_SIZE'(id_ex_reg.inst.r.funct3[1:0]); <-- HOW TO FIND THIS. the size of the data to store. Will be BYTE, HALF, or WORD
    
    //NOTE:the "st_" items should be sent to SQ as soon as the address to store to is resolved and the process begins. Once the data is sent to the SQ, the store FU's job is complete.
    //In addition, we still want to set their complete flags in the rob after execution is complete so that we can retire them.
} execute2sq;

typedef struct packed {
    logic       [`LD_BAY_SZ-1:0] forward_req_en; //tells the SQ that a store-load forwarding request is coming in on that line (bus, not count)
    LSQ_IDX     [`LD_BAY_SZ-1:0] forward_sq_idx; //the SQ IDXs of the loads that are requesting a forward (all loads are assigned the SQ_IDX of the store that most recently was dispatched in the ID_RESULT packet)
    ADDR        [`LD_BAY_SZ-1:0] forward_addr; //the address of the forwarding request
    MEM_SIZE    [`LD_BAY_SZ-1:0] forward_mem_size; //MEM_SIZE'(id_ex_reg.inst.r.funct3[1:0]); <-- HOW TO FIND THIS. the size of teh data forward requested. Will be BYTE, HALF, or WORD
} executeLD2sq;

typedef struct packed {
    logic       [`LD_BAY_SZ-1:0]          forward_en; //tells the load FU if valid data to be forwarded was found (will be ready by the posedge of the next clock cycle)
    DATA        [`LD_BAY_SZ-1:0]          forward_data; //the data being forwarded
    MEM_SIZE    [`LD_BAY_SZ-1:0]          forward_mem_size; //the size of the data being forwarded. Will always match the size of the request
    logic       [`LD_BAY_SZ-1:0] [3:0]    forward_byte_en; //a 4-wide mask telling which of the bytes are valid data being forwarded. This allows cases where you request 4000-4003, and SQ returns a match on 400-4001 and 4003 but not 4002 (and similar cases)
    //example for byte mask:
    //request addr 4000 size WORD
    //SQ match 4000-4001 (HALF)
    //SQ match 4003 (BYTE)
    //Return data 32'b: 4003 4002 4001 4000
    //byte mask:   4'b   1    0    1    1
} sq2execute;

typedef struct packed {
    logic   [$clog2(`N):0]  complete_en;
    ROB_IDX [`N-1:0]        complete_rob_idxs;
    logic                   sq_ret_complete;
} sq2rob;

typedef struct packed {
    logic   [$clog2(`N):0]  complete_en;
    ROB_IDX [`N-1:0]        complete_rob_idxs;
    logic                   sq_ret_complete;
} sq2retire;

typedef struct packed {
    logic   [$clog2(`N):0] r_en;
    // ROB_IDX [`N-1:0] r_pos;
} retire2sq;

typedef struct packed {
    MEM_COMMAND   Dmem_command;    // The memory command
    MEM_SIZE      Dmem_size;       // Size of data to read or write
    ADDR          Dmem_addr;       // Address sent to Data memory
    MEM_BLOCK     Dmem_store_data; // Data sent to Data memory
} stRET2mem;

typedef struct packed {
    logic       [$clog2(`N):0] ret_cnt;
    SQ_ENTRY    [`N-1:0] ret_st;
    logic       [`LD_BAY_SZ-1:0] forward_req_en;
    LSQ_IDX     [`LD_BAY_SZ-1:0] forward_sq_idx;
    ADDR        [`LD_BAY_SZ-1:0] forward_addr;
    MEM_SIZE    [`LD_BAY_SZ-1:0] forward_mem_size;
} sq2stRET;

typedef struct packed {
    logic [$clog2(`N):0]    free_scnt;
    logic [$clog2(`N):0]    used_scnt;
} stRET2sq;

typedef struct packed {
    logic       [`LD_BAY_SZ-1:0]          forward_en;
    ADDR        [`LD_BAY_SZ-1:0]          forward_addr;
    DATA        [`LD_BAY_SZ-1:0]          forward_data;
    MEM_SIZE    [`LD_BAY_SZ-1:0]          forward_mem_size;
    logic       [`LD_BAY_SZ-1:0] [3:0]    forward_byte_en;
    logic       [`LD_BAY_SZ-1:0]          sq_idx_found;    
} forwardRET2sq;

typedef struct packed {
    logic   [$clog2(`N):0]      lq_rdy_scnt;
    logic   [$clog2(`LSQ_SZ):0] lq_tail;
} lq2dispatch;

typedef struct packed {
    ADDR [`N-1:0] PC;
    logic[`N-1:0] err_ld_ooo;
} lq2retire;

typedef struct packed {
    logic   [$clog2(`N):0] r_en;
    ROB_IDX [`N-1:0] r_pos;
} retire2lq;

typedef struct packed {
    logic       [`NUM_FU_LOAD-1:0]  ld_ex_en; //tells LQ that a valid load is coming in on that line (bus, not count)
    LSQ_IDX     [`NUM_FU_LOAD-1:0]  ld_lq_idx; //LQ IDX for the incoming loads (found in ID_RESULT packet).
    ADDR        [`NUM_FU_LOAD-1:0]  ld_addr; //address that the load is loading from
    MEM_SIZE    [`NUM_FU_LOAD-1:0]  ld_mem_size; //MEM_SIZE'(id_ex_reg.inst.r.funct3[1:0]); <-- HOW TO FIND THIS. size being loaded (BYTE, HALF, WORD)
    //LQ doesn't need to talk back to execute

    //NOTE: the "ld_" items should be sent to LQ as soon as the address to load from is resolved and the query begins. In addition, we still want to set their complete flags in the
    //rob after execution is complete so that we can retire them.

    //NOTE: the "st_" items should be sent to LQ as soon as the address to store to is resolved and the data is being sent to the SQ.
} execute2lq;

typedef struct packed {
    logic       [`NUM_FU_STORE-1:0] st_en; //this comes from the STORE FUs, and tells the LQ if a valid SQ IDX is coming in on that line (bus, not count)
    LSQ_IDX     [`NUM_FU_STORE-1:0] st_sq_idx; //SQ_IDX associated with st_en. These two items are used to check if any loads and stores have happened out-of-order to flag in the ROB
} execeuteST2lq;

typedef struct packed {
    ADDR  addr;
    logic valid;
} MSHR_entry;

/* DEBUG STRUCTS */
typedef struct packed {
    // internal state
    logic changed_addr;
    logic [12-`ICACHE_LINE_BITS:0] current_tag,   last_tag,   write_tag;
    logic [`ICACHE_LINE_BITS -1:0] current_index, last_index, write_index;
    logic                          got_mem_data;
    MSHR_entry [15:0] MSHR;
    ICACHE_TAG [`ICACHE_LINES-1:0] icache_tags;
    // I/O
    MEM_TAG   Imem2proc_transaction_tag;
    MEM_BLOCK Imem2proc_data;
    MEM_TAG   Imem2proc_data_tag;
    ADDR proc2Icache_addr;
    MEM_COMMAND proc2Imem_command;
    ADDR        proc2Imem_addr;
    MEM_BLOCK Icache_data_out;
    logic     Icache_valid_out;
} DBG_icache;

typedef struct packed {
    // internal state
    // I/O
    logic           flush;
    decode2fetch    d_in;
    fetch2decode    d_out;
    retire2fetch    r_in;
    MEM_BLOCK [1:0] Imem_data;
    ADDR [`N-1:0]   PC_reg;
    // submodule
    DBG_icache      dbg_icache;
} DBG_fetch;

typedef struct packed {
    // internal state
    // I/O
    fetch2decode    f_in;
    decode2fetch    f_out;
    dispatch2decode d_in;
    decode2dispatch d_out;
} DBG_decode;

typedef struct packed {
    // internal state
    // I/O
    decode2dispatch decode_in;
    dispatch2decode decode_out;
    rs2dispatch rs_in;
    dispatch2rs rs_out;
    rob2dispatch rob_in;
    dispatch2rob rob_out;
    free_list2dispatch free_in;
    dispatch2free_list free_out;
    sq2dispatch sq_in;
    dispatch2sq sq_out;
    btq2dispatch btq_in;
    dispatch2btq btq_out;
    execute2complete_tag ctag_in;
    map_table2dispatch map_in;
    dispatch2map_table map_out;
} DBG_dispatch;

typedef struct packed {
    // internal state
    BTQ_ENTRY [`BTQ_SZ-1:0]      state;
    logic [$clog2(`BTQ_SZ)-1:0]  head;
    logic [$clog2(`BTQ_SZ)-1:0]  tail;
    logic [$clog2(`BTQ_SZ):0]    used;
    // I/O
    retire2btq           r_in;
    btq2retire           r_out;
    execute2complete_dat cdat_in;
    dispatch2btq         d_in;
    btq2dispatch         d_out;
} DBG_btq;

typedef struct packed {
    // internal state
    SQ_ENTRY    [`LSQ_SZ-1:0]           state;
    logic       [$clog2(`LSQ_SZ)-1:0]    head;
    logic       [$clog2(`LSQ_SZ)-1:0]    tail;
    logic       [$clog2(`LSQ_SZ):0]      used;
    // I/O
    dispatch2lq dis_2_lq;
    execute2lq exec_2_lq;
    retire2lq retire_2_lq;

    lq2dispatch lq_2_dis;
} DBG_lq;


typedef struct packed {
    // internal state
    struct packed {
        PHYS_REG_IDX t;
    } [`NUM_ARCH_REG-1:0] entries;

    // I/O
    arch_map2map_table am_in;
    dispatch2map_table d_in;
    map_table2dispatch d_out;
} DBG_mt;

typedef struct packed {
    // internal state
    logic [`PHYS_REG_SZ_R10K-1:0][$bits(DATA)-1:0] file;
    // I/O
    execute2complete_dat cdat_in;
    execute2prf ex_in;
    prf2execute ex_out;
} DBG_prf;

typedef struct packed {
    // internal state
    ROB_ENTRY [`ROB_SZ-1:0]     state;
    logic [$clog2(`ROB_SZ)-1:0]  head;
    logic [$clog2(`ROB_SZ)-1:0]  tail;
    logic [$clog2(`ROB_SZ):0]   used;
    logic [$clog2(`ROB_SZ):0]   free;
    logic [$clog2(4*`N):0]      rsvd;
    // I/O
    rob2retire  r_out;
    retire_final r_in;
    execute2complete_dat cdat_in;
    rob2dispatch d_out;
    dispatch2rob d_in;
} DBG_rob;

typedef struct packed {
    // internal state
    RS_ENTRY [`RS_SZ-1:0] entries; // ms1 test: remove one RS entry (caught)
    // I/O
    dispatch2rs d_in;
    rs2dispatch d_out;
    execute2rs  ex_in;
    rs2execute  ex_out;
    execute2complete_tag ctag_in;
} DBG_rs;

typedef struct packed {
    // internal state
    SQ_ENTRY [`LSQ_SZ-1:0]     state;
    logic [$clog2(`LSQ_SZ)-1:0] head;
    logic [$clog2(`LSQ_SZ)-1:0] tail;
    logic [$clog2(`LSQ_SZ):0]   used;
    // I/O
    sq2stRET sq_2_ret;
    MEM_TAG mem2proc_transaction_tag;

    stRET2sq ret_2_sq;
    forwardRET2sq forward_ret_2_sq;
    stRET2mem ret_2_mem;
} DBG_retbuf;

typedef struct packed {
    // internal state
    SQ_ENTRY [`LSQ_SZ-1:0]     state;
    logic [$clog2(`LSQ_SZ)-1:0] head;
    logic [$clog2(`LSQ_SZ)-1:0] tail;
    logic [$clog2(`LSQ_SZ):0]   used;
    // I/O

    dispatch2sq   dis_2_sq;
    execute2sq    exec_2_sq;
    retire2sq     retire_2_sq;
    MEM_TAG       mem2proc_transaction_tag;

    sq2dispatch  sq_2_dis;
    sq2execute   sq_2_exec;
    // sq2rs sq_2_rs,
    sq2retire    sq_2_retire;
    stRET2mem    ret_2_mem;

    DBG_retbuf   dbg_retbuf;
} DBG_sq;

typedef struct packed {
    // internal state
    // I/O
    rob2retire rob_in;
    btq2retire btq_in;
    retire2btq btq_out;
    sq2retire sq_in;
    retire2sq sq_out;
    lq2retire lq_in;
    logic mispred;
    ADDR  mispred_target;
    retire_final retire_exec;
} DBG_retire;


`endif // __SYS_DEFS_SVH__
