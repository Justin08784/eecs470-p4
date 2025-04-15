`ifndef __EXECUTE_DEFS_SVH__
`define __EXECUTE_DEFS_SVH__

`include "sys_defs.svh"
`include "dcache.svh"

typedef struct packed {
    PHYS_REG_IDX t;
    ROB_IDX rob_idx;
    DATA data;
    BTQ_IDX btq_idx;
    logic take;
    logic is_brch;
} CPL_CAND;

/* Slices (or "views") of ID_RESULT needed for each FU type */
typedef struct packed {
    BYPASS_TAG      bytag;

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;
    BTQ_IDX         btq_idx;

    INST inst;
    ADDR PC;
    ADDR NPC;

    ALU_OPA_SELECT opa_select;
    ALU_OPB_SELECT opb_select;
    ALU_FUNC alu_func;
    logic    cond_branch;
    logic    uncond_branch;
} ID_ALU_VIEW;

typedef struct packed {
    BYPASS_TAG      bytag;

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;
    logic[2:0]      func;
} ID_MUL_VIEW;

typedef struct packed {
    BYPASS_TAG      bytag;
    // alu_func   = ALU_ADD;
    // opa_select = OPA_IS_RS1
    // opb_select = OPB_IS_I_IMM

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    DATA            opb;

    LSQ_IDX         lq_idx;
    LSQ_IDX         sq_idx;
    ROB_IDX         rob_idx;
    MEM_SIZE        mem_size;
    logic           rd_unsigned;
} ID_LOD_VIEW;

typedef struct packed {
    BYPASS_TAG      bytag;
    // alu_func   = ALU_ADD;
    // opa_select = OPA_IS_RS1
    // opb_select = OPB_IS_S_IMM

    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    DATA            opb;

    LSQ_IDX         sq_idx;
    ROB_IDX         rob_idx;
    MEM_SIZE        mem_size;
} ID_STR_VIEW;

typedef struct packed {
    DATA rs1;
    DATA rs2;
    ID_ALU_VIEW dat;
} ALU_REGS;
typedef struct packed {
    DATA rs1;
    DATA rs2;
    ID_MUL_VIEW dat;
} MUL_REGS;
typedef struct packed {
    DATA rs1;
    ID_LOD_VIEW dat;
} LOD_REGS;
typedef struct packed {
    DATA rs1;
    DATA rs2;
    ID_STR_VIEW dat;
} STR_REGS;

/* Operand data needed for each FU type */
typedef struct packed {
    DATA            opa, opb;
    DATA            rs1, rs2;
    ALU_FUNC        alu_func;
    logic   [2:0]   branch_func; // Which branch condition to check
    logic           cond_branch;
    logic           uncond_branch;

    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
    BTQ_IDX         btq_idx;
} ALU_OPS;

typedef struct packed {
    DATA        rs1, rs2;
    MULT_FUNC   func;

    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
} MUL_OPS;

/* CDB snooping/bypassing functions */
function automatic ALU_REGS alu_snoop(
    input ALU_REGS v,
    input execute2complete_dat cdat
);
    ALU_REGS rv = v;
    foreach (cdat.en[n]) begin
        if (!cdat.en[n] || cdat.ts[n] == '0)
            continue;
        if (rv.dat.t1 == cdat.ts[n])
            rv.rs1 = cdat.data[n];
        if (rv.dat.t2 == cdat.ts[n])
            rv.rs2 = cdat.data[n];
    end
    return rv;
endfunction

function automatic MUL_REGS mul_snoop(
    input MUL_REGS v,
    input execute2complete_dat cdat
);
    MUL_REGS rv = v;
    foreach (cdat.en[n]) begin
        if (!cdat.en[n] || cdat.ts[n] == '0)
            continue;
        if (rv.dat.t1 == cdat.ts[n])
            rv.rs1 = cdat.data[n];
        if (rv.dat.t2 == cdat.ts[n])
            rv.rs2 = cdat.data[n];
    end
    return rv;
endfunction

function automatic LOD_REGS lod_snoop(
    input LOD_REGS v,
    input execute2complete_dat cdat
);
    LOD_REGS rv = v;
    foreach (cdat.en[n]) begin
        if (!cdat.en[n] || cdat.ts[n] == '0)
            continue;
        if (rv.dat.t1 == cdat.ts[n])
            rv.rs1 = cdat.data[n];
    end
    return rv;
endfunction

function automatic STR_REGS str_snoop(
    input STR_REGS v,
    input execute2complete_dat cdat
);
    STR_REGS rv = v;
    foreach (cdat.en[n]) begin
        if (!cdat.en[n] || cdat.ts[n] == '0)
            continue;
        if (rv.dat.t1 == cdat.ts[n])
            rv.rs1 = cdat.data[n];
        if (rv.dat.t2 == cdat.ts[n])
            rv.rs2 = cdat.data[n];
    end
    return rv;
endfunction


typedef struct packed {
    logic           vld;

    logic           queried;
    logic           hit;        // ...in cache (== !miss). Could update each cycle via recheck.
    // hit, retry
    logic [3:0]     need_byte_mask;
    DATA_BLOCK      raw_dat;    // raw word from SQ/dcache. SHOULD NOT BE SHIFTED!
                                // ...actually should we just let SQ, dcache do the shifting?
                                // I think no...?
    // miss, retry
    MEM_TAG         miss_tag;   // valid iff miss_tag != 0

    // where to look / byte manip.
    LSQ_IDX         sq_idx;
    ADDR            addr;
    MEM_SIZE        mem_size;

    // CDB destination info
    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
} LOAD_BAY_ENTRY;

`define LDBUF_SZ 8
typedef struct packed {
    logic           vld;

    logic           got; // got data?
    DATA_BLOCK      dat;
    /*
    FIXME: Do we need to query SQ from the load buffer? We're waiting
    for the fill anyways, so no right? If not query SQ, we can get rid of
    need_byte_mask (since the whole double-word will fill) and sq_idx?
    */
    MEM_TAG         miss_tag;

    // byte manip.
    DW_ACCESS       acc;
    MEM_SIZE        mem_size;

    // CDB destination info
    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
} LOAD_BUF_ENTRY;

`endif // __EXECUTE_DEFS_SVH__