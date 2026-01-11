`ifndef __EXECUTE_DEFS_SVH__
`define __EXECUTE_DEFS_SVH__

`include "sys_defs.svh"

typedef struct packed {
    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
    DATA            data;
} CPL_CAND;

/* Slices (or "views") of ID_RENAME_PKT needed for each FU type */
typedef struct packed {
    BYPASS_TAG      bytag;

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;

    INST inst;
    WADDR PC;

    ALU_OPA_SELECT opa_select;
    ALU_OPB_SELECT opb_select;
    ALU_FUNC alu_func;
} ID_ALU_VIEW;

typedef struct packed {
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;
    MUL_FUNC        func;
} ID_MUL_VIEW;

typedef struct packed {
    // alu_func   = ALU_ADD;
    // opa_select = OPA_IS_RS1
    // opb_select = OPB_IS_I_IMM

    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    DATA            opb;

    // LSQ_IDX         lq_idx;
    DSQ_IDX         dsq_idx;
    LQ_IDX          lq_idx;
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

    DSQ_IDX         dsq_idx;
    ROB_IDX         rob_idx;
    MEM_SIZE        mem_size;
} ID_STR_VIEW;

typedef struct packed {
    BYPASS_TAG      bytag;
    BMASK           b1hot;

    logic           has_dst;
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;
    BTQ_IDX         btq_idx;

    INST inst;
    WADDR PC;
    logic          cond_branch;
    ALU_OPA_SELECT opa_select;
    ALU_OPB_SELECT opb_select;
} ID_BRU_VIEW;


typedef struct packed {
    BYPASS_TAG      bytag;
    union packed {
        DATA    rs1;
        DATA    imm32a;
    } opa;
    union packed {
        DATA    rs2;
        DATA    imm32b;
    } opb;

    logic           opa_is_rs1;
    logic           opb_is_rs2;
    ALU_FUNC        alu_func;

    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
} ALU_REGS;

typedef struct packed {
    DATA            rs1;
    DATA            rs2;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;

    MUL_FUNC        func;

    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
} MUL_REGS;

typedef struct packed {
    DATA rs1;
    ID_LOD_VIEW dat;
} LOD_REGS;

typedef struct packed {
    BYPASS_TAG bytag;
    DATA rs1;
    DATA rs2;
    ID_STR_VIEW dat;
} STR_REGS;

typedef struct packed {
    BYPASS_TAG      bytag;
    BMASK           b1hot;

    DATA            rs1;
    DATA            rs2;

    WADDR           PC;
    ALU_OPA_SELECT  opa_select;
    logic           opb_is_rs2;
    INST            imm32b;
    logic           cond_branch;
    logic   [2:0]   func;       // Which branch condition to check

    logic           has_dst;
    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
    BTQ_IDX         btq_idx;
} BRU_REGS;


/* CDB snooping/bypassing functions */
function automatic ALU_REGS alu_snoop(
    input ALU_REGS v,
    input execute2complete_dat cdat
);
    ALU_REGS rv = v;
    if (rv.bytag.bypass1 && rv.opa_is_rs1)
        rv.opa = cdat.data[rv.bytag.cdb_idx1];
    if (rv.bytag.bypass2 && rv.opb_is_rs2)
        rv.opb = cdat.data[rv.bytag.cdb_idx2];
    return rv;
endfunction

function automatic MUL_REGS mul_snoop(
    input MUL_REGS v,
    input execute2complete_dat cdat
);
    MUL_REGS rv = v;
    foreach (cdat.en[n]) begin
        if (!cdat.en[n])
            continue;
        if (rv.t1 == cdat.ts[n])
            rv.rs1 = cdat.data[n];
        if (rv.t2 == cdat.ts[n])
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
        if (!cdat.en[n])
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
    if (rv.bytag.bypass1)
        rv.rs1 = cdat.data[rv.bytag.cdb_idx1];
    if (rv.bytag.bypass2)
        rv.rs2 = cdat.data[rv.bytag.cdb_idx2];
    return rv;
endfunction

function automatic BRU_REGS bru_snoop(
    input BRU_REGS v,
    input execute2complete_dat cdat
);
    BRU_REGS rv = v;
    if (rv.bytag.bypass1)
        rv.rs1 = cdat.data[rv.bytag.cdb_idx1];
    if (rv.bytag.bypass2)
        rv.rs2 = cdat.data[rv.bytag.cdb_idx2];
    return rv;
endfunction
`endif // __EXECUTE_DEFS_SVH__
