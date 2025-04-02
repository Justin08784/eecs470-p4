/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_ex.sv                                         //
//                                                                     //
//  Description :  instruction execute (EX) stage of the pipeline;     //
//                 given the instruction command code CMD, select the  //
//                 proper input A and B for the ALU, compute the       //
//                 result, and compute the condition for branches, and //
//                 pass all the results down the pipeline.             //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"
`include "ISA.svh"

/*
Flow chart
[Reservation Station] 
     ↓
[Staging FIFO (s_buf)]  ← just buffers instruction for 1 cycle
     ↓
[ops register (alu_ops, mul_ops)]  ← PRF values fetched here
     ↓
[Functional Unit (ALU or MUL)]
     ↓
[Completion FIFO (cpl_buf)] ← waits for CDB slot
     ↓
[ CDB Output Reg (c_out) ] ← selected for writeback this cycle
*/

typedef struct packed {
    PHYS_REG_IDX t;
    ROB_IDX rob_idx;
    DATA data;
    BTQ_IDX btq_idx;
    logic take;
    logic is_brch;
} CPL_CAND;

typedef struct packed {
    CPL_CAND [`NUM_FU_ALU-1:0]  alu;
    CPL_CAND [`NUM_FU_MULT-1:0] mul;
} CPL_CAND_BY_FU;

/* Slices (or "views") of ID_RESULT needed for each FU type */
typedef struct packed {
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
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;
    logic[2:0]      func;
} ID_MUL_VIEW;

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
    logic       bsy;
    DATA        rs1, rs2;
    MULT_FUNC   func;
    DST         dst;
} MUL_OPS;

// ALU: computes the result of FUNC applied with operands A and B
// This module is purely combinational
module alu (
    input DATA      opa,
    input DATA      opb,
    input DATA      rs1,
    input DATA      rs2,
    input ALU_FUNC  alu_func,
    input [2:0]     branch_func, // Which branch condition to check

    output logic    take, // True/False condition result
    output DATA     result
);

    always_comb begin
        case (alu_func)
            ALU_ADD:  result = opa + opb;
            ALU_SUB:  result = opa - opb;
            ALU_AND:  result = opa & opb;
            ALU_SLT:  result = signed'(opa) < signed'(opb);
            ALU_SLTU: result = opa < opb;
            ALU_OR:   result = opa | opb;
            ALU_XOR:  result = opa ^ opb;
            ALU_SRL:  result = opa >> opb[4:0];
            ALU_SLL:  result = opa << opb[4:0];
            ALU_SRA:  result = signed'(opa) >>> opb[4:0]; // arithmetic from logical shift
            // here to prevent latches:
            default:  result = 32'hfacebeec;
        endcase
    end

    always_comb begin
        case (branch_func)
            3'b000:  take = signed'(rs1) == signed'(rs2); // BEQ
            3'b001:  take = signed'(rs1) != signed'(rs2); // BNE
            3'b100:  take = signed'(rs1) <  signed'(rs2); // BLT
            3'b101:  take = signed'(rs1) >= signed'(rs2); // BGE
            3'b110:  take = rs1 <  rs2;                    // BLTU
            3'b111:  take = rs1 >= rs2;                   // BGEU
            default: take = `FALSE;
        endcase
    end

endmodule // alu


module alu_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic [`NUM_FU_ALU-1:0]          ex_rdy,
        // ready to accept from alu_ins?
    input [`NUM_FU_ALU-1:0]                 en,
        // insns to accept from alu_ins
    ALU_OPS [`NUM_FU_ALU-1:0] ops,
        // insn metadata/operands

    /* BACKEND */
    output logic [`NUM_FU_ALU-1:0]      vld,
    output CPL_CAND [`NUM_FU_ALU-1:0]   cands,
        // completion requests
    input  logic [`NUM_FU_ALU-1:0]      cpl_gnt
        // completion grant
);
    // execute
    generate
        CPL_CAND    [`NUM_FU_ALU-1:0] tmp_data;
        DATA        [`NUM_FU_ALU-1:0] tmp_res;
        logic       [`NUM_FU_ALU-1:0] tmp_take;
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            alu alu_0 ( 
                // Inputs
                .opa        (ops[i].opa),
                .opb        (ops[i].opb),
                .rs1        (ops[i].rs1),
                .rs2        (ops[i].rs2),
                .alu_func   (ops[i].alu_func),
                .branch_func(ops[i].branch_func), // Which branch condition to check

                .take(tmp_take[i]), // True/False condition result (will return FALSE if branch is low)
                .result(tmp_res[i]) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
            );

            assign tmp_data[i] = '{
                t       : ops[i].t,
                rob_idx : ops[i].rob_idx,
                data    : tmp_res[i],
                btq_idx : ops[i].btq_idx,
                take    : tmp_take[i],
                is_brch : ops[i].cond_branch || ops[i].uncond_branch
            };

            // <FU>_outs: where executed insns wait until completion
            ppln_skid #(
                .WIDTH($bits(CPL_CAND))
            ) cpl_buf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (en[i]),
                .i_rdy (ex_rdy[i]),
                .i_dat (tmp_data[i]),

                .o_vld (vld[i]),
                .o_rdy (cpl_gnt[i]),
                .o_dat (cands[i])
            );
        end
    endgenerate
endmodule

module mul_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic [`NUM_FU_MULT-1:0]     ex_rdy,
        // ready to accept from mul_ins?
    input [`NUM_FU_MULT-1:0]            en,
        // insns to accept from mul_ins
    MUL_OPS [`NUM_FU_MULT-1:0] ops,
        // insn metadata/operands

    /* BACKEND */
    output logic [`NUM_FU_MULT-1:0]     vld,
    output CPL_CAND [`NUM_FU_MULT-1:0]  cands,
        // completion requests
    input  logic [`NUM_FU_MULT-1:0]     cpl_gnt
        // completion grant
);
    // execute
    generate
        logic       [`NUM_FU_MULT-1:0] tmp_out_vld;
        DATA        [`NUM_FU_MULT-1:0] tmp_res;
        DST         [`NUM_FU_MULT-1:0] tmp_dst;
        CPL_CAND    [`NUM_FU_MULT-1:0] tmp_data;

        logic       [`NUM_FU_MULT-1:0] cpl_buf_rdy;
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mults
            mult mult_0 ( 
                .clock  (clock),
                .reset  (reset),
                .flush  (flush),
                .in_vld (en[i]),
                .out_rdy(cpl_buf_rdy[i]),
                .dst_in (ops[i].dst),
                .rs1    (ops[i].rs1),
                .rs2    (ops[i].rs2),
                .func   (ops[i].func),

                // Output
                .dst_out(tmp_dst[i]),
                .result (tmp_res[i]),
                .in_rdy (ex_rdy[i]),
                .out_vld(tmp_out_vld[i])
            );

            assign tmp_data[i] = '{
                t       : tmp_dst[i].tag,
                rob_idx : tmp_dst[i].rob_idx,
                data    : tmp_res[i],
                btq_idx : '0,
                take    : '0,
                is_brch : '0
            };

            // <FU>_outs: where executed insns wait until completion
            ppln_skid #(
                .WIDTH($bits(CPL_CAND))
            ) cpl_buf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (tmp_out_vld[i]),
                .i_dat (tmp_data[i]),
                .i_rdy (cpl_buf_rdy[i]),

                .o_vld (vld[i]),
                .o_rdy (cpl_gnt[i]),
                .o_dat (cands[i])

            );
           
        end
    endgenerate
endmodule

module stage_ex_p4 (
    input clock,
    input reset,
    input flush,

    input   rs2execute rs_in,
    output  execute2rs rs_out,

    input   prf2execute prf_in,
    output  execute2prf prf_out,

    // TODO: wrap this stuff into execute2complete. Wrap crap here in general.
    output  execute2complete c_out

);

    // <FU>_ins: staging; where just-issued insns wait for 1 cycle to pull their operands
    struct packed {
        LOGIC_BY_FU     i_rdy;
        LOGIC_BY_FU     o_vld;
        struct packed {
            ID_ALU_VIEW [`NUM_FU_ALU-1:0]   alu;
            ID_MUL_VIEW [`NUM_FU_MULT-1:0]  mul;
        } dat;
    } iss;

    struct packed {
        LOGIC_BY_FU i_rdy;
        LOGIC_BY_FU o_vld;
        struct packed {
            ALU_OPS [`NUM_FU_ALU-1:0]   alu; // TODO: unused
            MUL_OPS [`NUM_FU_MULT-1:0]  mul; // TODO: unused
        } dat;
    } ops;
    
    LOGIC_BY_FU iss2ops_en;
    assign iss2ops_en = iss.o_vld & ops.i_rdy;
    generate
        /* Staging buffers (sbufs):

        Size 2 is the minimum FIFO depth (without internal forwarding) that supports
        a 1-write-per-cycle producer and 1-read-per-cycle consumer at steady state
        with no bubbles.

        The point of this staging buffer is to break comb. dependencies between:
            1) backpressure emanating from <FU>_ops_rdy and
            2) issue selection logic in RS
        Adding internal forwarding would defeat its entire purpose.
        */
        // TODO: Make these into FIFOs with only the subset of fields needed
        // for the ALU type. Conserve space.
        ID_ALU_VIEW tmp_alu_el[`NUM_FU_ALU-1:0];
        ID_MUL_VIEW tmp_mul_el[`NUM_FU_MULT-1:0];

        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alu_sbufs
            assign tmp_alu_el[i] = '{
                t       : rs_in.fu_dat_alu[i].t,
                t1      : rs_in.fu_dat_alu[i].t1,
                t2      : rs_in.fu_dat_alu[i].t2,
                rob_idx : rs_in.fu_dat_alu[i].rob_idx,
                btq_idx : rs_in.fu_dat_alu[i].btq_idx,

                inst    : rs_in.fu_dat_alu[i].inst,
                PC      : rs_in.fu_dat_alu[i].PC,
                NPC     : rs_in.fu_dat_alu[i].NPC,

                opa_select  : rs_in.fu_dat_alu[i].opa_select,
                opb_select  : rs_in.fu_dat_alu[i].opb_select,
                alu_func    : rs_in.fu_dat_alu[i].alu_func,
                cond_branch : rs_in.fu_dat_alu[i].cond_branch,
                uncond_branch : rs_in.fu_dat_alu[i].uncond_branch
            };

            ppln_skid #(
                .WIDTH($bits(ID_ALU_VIEW))
            ) cpl_buf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_vld_alu[i]),
                .i_rdy (iss.i_rdy.alu[i]),
                .i_dat (tmp_alu_el[i]),

                .o_vld (iss.o_vld.alu[i]),
                .o_rdy (ops.i_rdy.alu[i]),
                .o_dat (iss.dat.alu[i])
            );
        end
        
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mul_sbufs
            assign tmp_mul_el[i] = '{
                t       : rs_in.fu_dat_mult[i].t,
                t1      : rs_in.fu_dat_mult[i].t1,
                t2      : rs_in.fu_dat_mult[i].t2,
                rob_idx : rs_in.fu_dat_mult[i].rob_idx,
                func    : rs_in.fu_dat_mult[i].inst.r.funct3
            };
            ppln_skid #(
                .WIDTH($bits(ID_MUL_VIEW))
            ) cpl_buf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_vld_mult[i]),
                .i_rdy (iss.i_rdy.mul[i]),
                .i_dat (tmp_mul_el[i]),

                .o_vld (iss.o_vld.mul[i]),
                .o_rdy (ops.i_rdy.mul[i]),
                .o_dat (iss.dat.mul[i])
            );
        end
    endgenerate

    // request operands from PRF (separate stage)
    /*
    TODO: A separate PRF + operand fetch/decode stage is UNACCEPTABLE for performance,
    as it adds 1 cycle delay to waking dependent insns. We MUST move PRF read
    forward to issue, and operand decode into <FU>_ex.
    */
    always_comb begin
        prf_out = '0;
        foreach (iss2ops_en.alu[i]) begin
            if (!iss2ops_en.alu[i])
                continue;
            prf_out.s_en1s.alu[i]   = 1;
            prf_out.s_en2s.alu[i]   = 1;
            prf_out.s_t1s.alu[i]    = iss.dat.alu[i].t1; 
            prf_out.s_t2s.alu[i]    = iss.dat.alu[i].t2; 
        end
        foreach (iss2ops_en.mul[i]) begin
            if (!iss2ops_en.mul[i])
                continue;
            prf_out.s_en1s.mul[i]   = 1;
            prf_out.s_en2s.mul[i]   = 1;
            prf_out.s_t1s.mul[i]    = iss.dat.mul[i].t1; 
            prf_out.s_t2s.mul[i]    = iss.dat.mul[i].t2; 
        end
    end

    struct packed {
        LOGIC_BY_FU rdy;
        LOGIC_BY_FU vld;
    } regs;
    typedef struct packed {
        DATA src1;
        DATA src2;
        ID_ALU_VIEW dat;
    } ALU_REGS_EX;
    typedef struct packed {
        DATA src1;
        DATA src2;
        ID_MUL_VIEW dat;
    } MUL_REGS_EX;

    // receive/decode operands from PRF
    ALU_OPS [`NUM_FU_ALU-1:0]   alu_ops;
    ALU_OPS [`NUM_FU_ALU-1:0]   tmp_alu_ops;
    MUL_OPS [`NUM_FU_MULT-1:0]  mul_ops;
    MUL_OPS [`NUM_FU_MULT-1:0]  tmp_mul_ops;

    struct packed {
        LOGIC_BY_FU i_rdy;
        LOGIC_BY_FU o_vld;
    } ex;
    always_comb begin
        tmp_alu_ops = '0;
        foreach(iss2ops_en.alu[i]) begin
            if(!iss2ops_en.alu[i]) 
                continue;
            tmp_alu_ops[i].rs1 = prf_in.s_v1s.alu[i];
            tmp_alu_ops[i].rs2 = prf_in.s_v2s.alu[i];

            // ALU opA mux
            case (iss.dat.alu[i].opa_select)
                OPA_IS_RS1:  tmp_alu_ops[i].opa = prf_in.s_v1s.alu[i];
                OPA_IS_NPC:  tmp_alu_ops[i].opa = iss.dat.alu[i].NPC;
                OPA_IS_PC:   tmp_alu_ops[i].opa = iss.dat.alu[i].PC;
                OPA_IS_ZERO: tmp_alu_ops[i].opa = 0;
                default:     tmp_alu_ops[i].opa = 32'hdeadface; // dead face
            endcase

            // ALU opB mux
            case (iss.dat.alu[i].opb_select)
                OPB_IS_RS2:   tmp_alu_ops[i].opb =  prf_in.s_v2s.alu[i];
                OPB_IS_I_IMM: tmp_alu_ops[i].opb = `RV32_signext_Iimm(iss.dat.alu[i].inst);
                OPB_IS_S_IMM: tmp_alu_ops[i].opb = `RV32_signext_Simm(iss.dat.alu[i].inst);
                OPB_IS_B_IMM: tmp_alu_ops[i].opb = `RV32_signext_Bimm(iss.dat.alu[i].inst);
                OPB_IS_U_IMM: tmp_alu_ops[i].opb = `RV32_signext_Uimm(iss.dat.alu[i].inst);
                OPB_IS_J_IMM: tmp_alu_ops[i].opb = `RV32_signext_Jimm(iss.dat.alu[i].inst);
                default:      tmp_alu_ops[i].opb = 32'hfacefeed; // face feed
            endcase

            tmp_alu_ops[i].alu_func    = iss.dat.alu[i].alu_func;
            tmp_alu_ops[i].branch_func = iss.dat.alu[i].inst.b.funct3;
            tmp_alu_ops[i].t           = iss.dat.alu[i].t;
            tmp_alu_ops[i].rob_idx     = iss.dat.alu[i].rob_idx;
            tmp_alu_ops[i].btq_idx     = iss.dat.alu[i].btq_idx;
            tmp_alu_ops[i].cond_branch        = iss.dat.alu[i].cond_branch;
            tmp_alu_ops[i].uncond_branch      = iss.dat.alu[i].uncond_branch;
        end

        tmp_mul_ops = '0;
        foreach (iss2ops_en.mul[i]) begin
            if (!iss2ops_en.mul[i])
                continue;
            tmp_mul_ops[i].rs1 = prf_in.s_v1s.mul[i];
            tmp_mul_ops[i].rs2 = prf_in.s_v2s.mul[i];
            tmp_mul_ops[i].func = iss.dat.mul[i].func;
            tmp_mul_ops[i].dst = '{
                rob_idx : iss.dat.mul[i].rob_idx,
                tag     : iss.dat.mul[i].t
            };
        end
    end

    generate
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alu_rbufs
            ppln_skid #(
                .WIDTH($bits(ALU_OPS))
            ) rbuf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (iss.o_vld.alu[i]),
                .i_rdy (ops.i_rdy.alu[i]),
                .i_dat (tmp_alu_ops[i]),

                .o_vld (ops.o_vld.alu[i]),
                .o_rdy (ex.i_rdy.alu[i]),
                .o_dat (alu_ops[i])
            );
        end

        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mul_rbufs
            ppln_skid #(
                .WIDTH($bits(MUL_OPS))
            ) rbuf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (iss.o_vld.mul[i]),
                .i_rdy (ops.i_rdy.mul[i]),
                .i_dat (tmp_mul_ops[i]),

                .o_vld (ops.o_vld.mul[i]),
                .o_rdy (ex.i_rdy.mul[i]),
                .o_dat (mul_ops[i])
            );
        end
    endgenerate


    // structure results into generic cdb candidates array
    CPL_CAND_BY_FU cands;
    CPL_CAND [`NUM_FU_TOTAL-1:0] cands_flat;
    assign cands_flat = cands;

    logic [`N-1:0][`NUM_FU_TOTAL-1:0] cdb2fu_gbus;
    LOGIC_BY_FU cpl_gnt;

    LOGIC_BY_FU ops2ex_en;
    assign ops2ex_en.alu = ops.o_vld.alu & ex.i_rdy.alu;
    alu_ex alu_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .en     (ops2ex_en.alu),
        .ops    (alu_ops),
        .ex_rdy (ex.i_rdy.alu),

        .vld    (ex.o_vld.alu),
        .cands  (cands.alu),
        .cpl_gnt(cpl_gnt.alu)
    );

    assign ops2ex_en.mul = ops.o_vld.mul & ex.i_rdy.mul;
    mul_ex mul_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .en     (ops2ex_en.mul),
        .ops    (mul_ops),
        .ex_rdy (ex.i_rdy.mul),

        .vld    (ex.o_vld.mul),
        .cands  (cands.mul),
        .cpl_gnt(cpl_gnt.mul)
    );

    psel_gen #(
        .WIDTH(`NUM_FU_TOTAL),
        .REQS(`N)
    ) sel_cpl (
        .req(ex.o_vld), // flatten (alu + mul bits) => single [NUM_FU_TOTAL-1:0] bus
        .gnt(cpl_gnt),  // flatten => single bus
        .gnt_bus(cdb2fu_gbus)
    );

    execute2complete c_out_n;
    always_comb begin
        rs_out = '{
            fu_rdy_alu      : iss.i_rdy.alu,
            fu_rdy_mult     : iss.i_rdy.mul,
            fu_rdy_load     : '0,
            fu_rdy_store    : '0
        };

        c_out_n = '0;
        foreach (cdb2fu_gbus[c, f]) begin
            if (cdb2fu_gbus[c][f]) begin
                c_out_n.c_en[c]       |= 1;
                c_out_n.c_ts[c]       |= cands_flat[f].t;
                c_out_n.c_rob_idxs[c] |= cands_flat[f].rob_idx;
                c_out_n.c_data[c]     |= cands_flat[f].data;
                // TODO: fill these
                c_out_n.btq_idxs[c]   |= cands_flat[f].btq_idx;
                c_out_n.is_branch[c]  |= cands_flat[f].is_brch;
                c_out_n.take[c]       |= cands_flat[f].take;
            end
        end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            c_out       <= '0;
        end else begin
            /*
            We buffer c_out for 1 cycle to break the comb. chain...
            cpl_buf.used_scnt(vld) -> psel_gen(vld) -> cpl_buf.rd_en_cnt(cpl_gnt)
            -> cpl_buf.rd_data(cands) -> c_out $#BREAK HERE#$ -> RS issue
            -> FU sbuf.wr_data()

            TODO: Buffering c_out for 1 cycle feels a little questionable.
            Are you sure you're not adding an unnecessary cycle of latency for
            free_list and rob who practically already wait for 1 cycle because
            they have INTR_FWD disabled? Can you simply reenable INTR_FWD for
            them with minimal latency cost?
            */
            c_out       <= c_out_n;

        end
    end

    `ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | >> EXECUTE", $time);

            for (int i = 0; i < `NUM_FU_ALU; ++i) begin
                $display("alu_ins[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, btq_idx: %2d, inst: 0x%x, PC: 0x%x, NPC: 0x%x, cond_branch: %b, uncond_branch: %b",
                    i,
                    iss.i_rdy.alu[i],
                    iss.o_vld.alu[i],
                    iss.dat.alu[i].t,
                    iss.dat.alu[i].t1,
                    iss.dat.alu[i].t2,
                    iss.dat.alu[i].rob_idx,
                    iss.dat.alu[i].btq_idx,
                    iss.dat.alu[i].inst,
                    iss.dat.alu[i].PC,
                    iss.dat.alu[i].NPC,
                    iss.dat.alu[i].cond_branch,
                    iss.dat.alu[i].uncond_branch
                );
            end

            for (int i = 0; i < `NUM_FU_MULT; ++i) begin
                $display("mul_ins[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, func: 0x%x",
                    i,
                    iss.i_rdy.mul[i],
                    iss.o_vld.mul[i],
                    iss.dat.mul[i].t,
                    iss.dat.mul[i].t1,
                    iss.dat.mul[i].t2,
                    iss.dat.mul[i].rob_idx,
                    iss.dat.mul[i].func
                );
            end

            for (int i = 0; i < `NUM_FU_ALU; ++i) begin
                $display("alu_ops[%0d]: bsy: %b, opa: 0x%x, opb: 0x%x, alu_func: %b, branch_func: %b, cond_branch: %b, uncond_branch: %b, t: %2d, rob_idx: %2d, btq_idx: %2d",
                    i,
                    ops.o_vld.alu[i],
                    alu_ops[i].opa,
                    alu_ops[i].opb,
                    alu_ops[i].alu_func,
                    alu_ops[i].branch_func,
                    alu_ops[i].cond_branch,
                    alu_ops[i].uncond_branch,
                    alu_ops[i].t,
                    alu_ops[i].rob_idx,
                    alu_ops[i].btq_idx
                );
            end

            for (int i = 0; i < `NUM_FU_MULT; ++i) begin
                $display("mul_ops[%0d]: bsy: %b, rs1: 0x%x, rs2: 0x%x, func: %b, t: %2d, rob_idx: %2d",
                    i,
                    ops.o_vld.mul[i],
                    mul_ops[i].rs1,
                    mul_ops[i].rs2,
                    mul_ops[i].func,
                    mul_ops[i].dst.tag,
                    mul_ops[i].dst.rob_idx
                );
            end

            $display("c_out: rdy_alu: %b  rdy_mult: %b  rdy_store: %b  rdy_load: %b  cpl_gnt: %b",
                rs_out.fu_rdy_alu,
                rs_out.fu_rdy_mult,
                rs_out.fu_rdy_store,
                rs_out.fu_rdy_load,
                cpl_gnt
            );

            for (int i = 0; i < `N; ++i) begin
                $display("c_out[%0d]: c_en: %b, is_branch: %b, c_ts: %2d, c_rob_idxs: %2d, c_data: %x, btq_idxs: %d, take: %b",
                    i,
                    c_out.c_en[i],
                    c_out.is_branch[i],
                    c_out.c_ts[i],
                    c_out.c_rob_idxs[i],
                    c_out.c_data[i],
                    c_out.btq_idxs[i],
                    c_out.take[i]
                );
            end


            // for (int i = 0; i < 4; ++i) begin
            //     $display("all_vld[%0d]: %b", i, all_vld[i]);
            // end
            // $display("all_vld: %b", all_vld);
            // $display("");
            // for (int i = 0; i < 4; ++i) begin
            //     $display("cpl_gnt[%0d]: %b", i, cpl_gnt[i]);
            // end
            // $display("cpl_gnt: %b", cpl_gnt);
            // $display("");
            // for (int c = 0; c < 2; ++c) begin
            //     for (int f = 0; f < 4; ++f) begin
            //         $display("cdb2fu_gbus[%0d][%0d]: %b", c, f, cdb2fu_gbus[c][f]);
            //     end
            // end
            // $display("");
            // for (int i = 0; i < 4; ++i) begin
            //     $display("cand[%0d]: t: %0d rob_idx: %0d data: %x", i, all_cands[i].t, all_cands[i].rob_idx, all_cands[i].data);
            // end
            // $display("<prf_out> en: %b s_t1s: [%0d, %0d, %0d, %0d] s_t2s: [%0d, %0d, %0d, %0d]",
            //     prf_out.prf_en,
            //     prf_out.s_t1s[0],
            //     prf_out.s_t1s[1],
            //     prf_out.s_t1s[2],
            //     prf_out.s_t1s[3],
            //     prf_out.s_t2s[0],
            //     prf_out.s_t2s[1],
            //     prf_out.s_t2s[2],
            //     prf_out.s_t2s[3]
            // );
            // $display("alu: (rdy: %b, res: %x), (rdy: %b, res: %x), mul: (rdy: %b, res: %x), (rdy: %b, res: %x)",
            //     alu_outs.rdy[0],
            //     alu_outs.res[0],
            //     alu_outs.rdy[1],
            //     alu_outs.res[1],
            //     mul_outs.rdy[0],
            //     mul_outs.res[0],
            //     mul_outs.rdy[1],
            //     mul_outs.res[1]
            // );
            $display("<prf_in >        s_v1s: [%0d, %0d, %0d, %0d] s_v2s: [%0d, %0d, %0d, %0d]",
                prf_in.s_v1s[0],
                prf_in.s_v1s[1],
                prf_in.s_v1s[2],
                prf_in.s_v1s[3],
                prf_in.s_v2s[0],
                prf_in.s_v2s[1],
                prf_in.s_v2s[2],
                prf_in.s_v2s[3]
            );
            $display("  %3d | << EXECUTE", $time);
        end
    end
    `endif // DEBUG

endmodule // stage_ex
