`ifndef __EXECUTE_DEFS_SVH__
`define __EXECUTE_DEFS_SVH__

`include "sys_defs.svh"

typedef struct packed {
    PHYS_REG_IDX t;
    ROB_IDX rob_idx;
    DATA data;
} CPL_CAND;

/* Slices (or "views") of ID_RESULT needed for each FU type */
typedef struct packed {
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
    MULT_FUNC       func;
} ID_MUL_VIEW;

typedef struct packed {
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
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;
    BTQ_IDX         btq_idx;

    INST inst;
    WADDR PC;
    logic    cond_branch;
    logic    uncond_branch;
    ALU_OPA_SELECT opa_select;
    ALU_OPB_SELECT opb_select;
} ID_BRU_VIEW;

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
typedef struct packed {
    DATA rs1;
    DATA rs2;
    ID_BRU_VIEW dat;
} BRU_REGS;

/* Operand data needed for each FU type */
typedef struct packed {
    DATA            opa, opb;
    DATA            rs1, rs2;
    ALU_FUNC        alu_func;

    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
} ALU_OPS;

typedef struct packed {
    DATA        rs1, rs2;
    MULT_FUNC   func;

    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
} MUL_OPS;

typedef struct packed {
    DATA            opa, opb;
    DATA            rs1, rs2;
    logic   [2:0]   branch_func; // Which branch condition to check
    logic           cond_branch;
    logic           uncond_branch;

    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
    BTQ_IDX         btq_idx;
} BRU_OPS;

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

function automatic BRU_REGS bru_snoop(
    input BRU_REGS v,
    input execute2complete_dat cdat
);
    BRU_REGS rv = v;
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
    execute2btq btq_out;
    execute2complete_tag ctag_out;
    execute2complete_dat cdat_out;

    struct packed {
        `BY_FU(logic)   i_rdy;
        `BY_FU(logic)   o_vld;
        struct packed {
            ID_ALU_VIEW [`NUM_FU_ALU-1:0]   alu;
            ID_MUL_VIEW [`NUM_FU_MULT-1:0]  mul;
            ID_LOD_VIEW [`NUM_FU_LOAD-1:0]  lod;
            ID_STR_VIEW [`NUM_FU_STORE-1:0] str;
        } i_dat, o_dat;
    } iss;

    struct packed {
        `BY_FU(logic) i_rdy;
        `BY_FU(logic) o_vld;
        struct packed {
            ALU_REGS [`NUM_FU_ALU-1:0]   alu;
            MUL_REGS [`NUM_FU_MULT-1:0]  mul;
            LOD_REGS [`NUM_FU_LOAD-1:0]  lod;
            STR_REGS [`NUM_FU_STORE-1:0] str;
        } i_dat, o_dat;
    } regs;

    `BY_FU(CPL_CAND) cands;
    CPL_CAND [`NUM_FU_TOTAL-1:0] cands_flat;

    `BY_FU(PHYS_REG_IDX) ctag_ts;
    PHYS_REG_IDX [`NUM_FU_TOTAL-1:0] ctag_ts_flat;

    logic [1:0][`N-1:0][`NUM_FU_TOTAL-1:0]  cdb2fu_gbus_shr;
    logic [`N-1:0][`NUM_FU_TOTAL-1:0]       cdb2fu_gbus;
    `BY_FU(logic) [1:0] cdb_gnt_shr;

    `BY_FU(logic) cdb_req;
    `BY_FU(logic) cdb_gnt;
} DBG_execute;

`endif // __EXECUTE_DEFS_SVH__
