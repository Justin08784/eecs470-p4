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
`include "execute.svh"
`include "ISA.svh"

/*
Flow chart
[Reservation Station] 
     ↓
[Staging FIFO (s_buf)]  ← just buffers instruction for 1 cycle
     ↓
[regs register (r_buf)]  ← PRF values fetched here
     ↓
[Functional Unit (ALU, MUL, LOD, or STR)]
     ↓
[CDB Output Reg (c_out)] ← selected for writeback this cycle

CDB arbitration:
- For 1-cycle op, arbitration occurs in [RS] -> [s_buf]
- For ≥ 4 cycle ops, it occurs in [FU]
- For < 4 cycle ops, it occurs *before* [FU] (but we dont support any
ops in this category, so we wouldn't know)
*/

// ALU: computes the result of FUNC applied with operands A and B
// This module is purely combinational
module alu (
    input DATA      opa,
    input DATA      opb,
    input ALU_FUNC  alu_func,

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
endmodule // alu


module alu_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    logic [`NUM_FU_ALU-1:0]             i_vld,
    input  ALU_REGS [`NUM_FU_ALU-1:0]   i_regs,
        // insn metadata/operands

    /* BACKEND */
    output CPL_CAND [`NUM_FU_ALU-1:0]   o_cands
);
    ALU_OPS [`NUM_FU_ALU-1:0] ops;
    ADDR    [`NUM_FU_ALU-1:0] pc_addrs, npc_addrs;
    always_comb begin
        DATA opa, opb;
        foreach(ops[i]) begin
            pc_addrs[i]     = w2addr(i_regs[i].PC);
            npc_addrs[i]    = w2addr(i_regs[i].PC + 1);
            // ALU opA mux
            case (i_regs[i].opa_select)
                OPA_IS_RS1:  opa = i_regs[i].rs1;
                OPA_IS_NPC:  opa = npc_addrs[i];
                OPA_IS_PC:   opa = pc_addrs[i];
                OPA_IS_ZERO: opa = 0;
                default:     opa = 32'hdeadface; // dead face
            endcase

            // ALU opB mux
            opb = i_regs[i].opb;

            ops[i] = '{
                opa         : opa,
                opb         : opb,
                alu_func    : i_regs[i].alu_func,
                t           : i_regs[i].t,
                rob_idx     : i_regs[i].rob_idx
            };
        end
    end

    // execute
    generate
        CPL_CAND    [`NUM_FU_ALU-1:0] tmp_data;
        DATA        [`NUM_FU_ALU-1:0] tmp_res;
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            alu alu_0 ( 
                // Inputs
                .opa        (ops[i].opa),
                .opb        (ops[i].opb),
                .alu_func   (ops[i].alu_func),

                // Output (directly to cdat_out)
                .result(tmp_res[i]) // will return 32'hfacebeec if branch is high
            );

            assign tmp_data[i] = '{
                t       : ops[i].t,
                rob_idx : ops[i].rob_idx,
                data    : tmp_res[i]
            };

            assign o_cands[i] = tmp_data[i];
        end
    endgenerate
endmodule

module mul_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic    [`NUM_FU_MUL-1:0]  i_rdy,
        // ready to accept from regs.o_dat.mul?
    input  logic    [`NUM_FU_MUL-1:0]  i_vld,
        // insns to accept from regs.o_dat.mul
    input  MUL_REGS [`NUM_FU_MUL-1:0]  i_regs,
        // insn metadata/operands

    /* Early CDB arbitration */
    output logic [`NUM_FU_MUL-1:0]     cdb_req,
    output PHYS_REG_IDX [`NUM_FU_MUL-1:0] ctag_ts,
    input  logic [`NUM_FU_MUL-1:0]     cdb_gnt,

    /* BACKEND */
    output CPL_CAND [`NUM_FU_MUL-1:0]  o_cands
);
    MUL_OPS [`NUM_FU_MUL-1:0] ops;
    always_comb begin
        foreach (ops[i]) begin
            ops[i] = '{
                rs1     : i_regs[i].rs1,
                rs2     : i_regs[i].rs2,
                func    : i_regs[i].func,
                t       : i_regs[i].t,
                rob_idx : i_regs[i].rob_idx
            };
        end
    end

    // execute
    generate
        DATA        [`NUM_FU_MUL-1:0] tmp_res;
        PHYS_REG_IDX[`NUM_FU_MUL-1:0] tmp_t;
        ROB_IDX     [`NUM_FU_MUL-1:0] tmp_rob_idx;

        logic       [`NUM_FU_MUL-1:0] cpl_buf_rdy;
        for (genvar i = 0; i < `NUM_FU_MUL; ++i) begin : gen_mults
            mult #(
                .ID(i)
            ) mult_0 ( 
                .clock,
                .reset,
                .flush,

                .i_vld  (i_vld[i]),
                .i_rdy  (i_rdy[i]),
                .rs1    (ops[i].rs1),
                .rs2    (ops[i].rs2),
                .func   (ops[i].func),
                .i_t    (ops[i].t),
                .i_rob_idx(ops[i].rob_idx),

                .cdb_req(cdb_req[i]),
                .ctag_t (ctag_ts[i]),
                .cdb_gnt(cdb_gnt[i]),

                // Output (directly to cdat_out)
                .o_t    (tmp_t[i]),
                .o_rob_idx(tmp_rob_idx[i]),
                .result (tmp_res[i])
            );

            assign o_cands[i] = '{
                t       : tmp_t[i],
                rob_idx : tmp_rob_idx[i],
                data    : tmp_res[i]
            };
        end
    endgenerate
endmodule

module bru (
    input DATA      opa,
    input DATA      opb,
    input DATA      rs1,
    input DATA      rs2,
    input [2:0]     branch_func, // Which branch condition to check

    output logic    take, // True/False condition result
    output DATA     result
);

    assign result = opa + opb;

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

endmodule // bru

module bru_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    input  logic [`NUM_FU_BRU-1:0]      i_vld,
    input  BRU_REGS [`NUM_FU_BRU-1:0]   i_regs,
        // insn metadata/operands

    /* BACKEND */
    output execute2btq                  o_btq_out,
    output CPL_CAND [`NUM_FU_BRU-1:0]   o_cands
);
    BRU_OPS [`NUM_FU_BRU-1:0] ops;
    ADDR    [`NUM_FU_BRU-1:0] pc_addrs, npc_addrs;
    always_comb begin
        DATA opa, opb;
        foreach(ops[i]) begin
            pc_addrs[i]     = w2addr(i_regs[i].PC);
            npc_addrs[i]    = w2addr(i_regs[i].PC + 1);
            // BRU opA mux
            case (i_regs[i].opa_select)
                OPA_IS_PC:   opa = pc_addrs[i];
                OPA_IS_RS1:  opa = i_regs[i].rs1;
                default:     opa = 32'hdeadface; // dead face
            endcase

            // BRU opB mux
            opb = i_regs[i].opb_is_rs2
                ? i_regs[i].rs2
                : i_regs[i].imm32b;

            ops[i] = '{
                opa         : opa,
                opb         : opb,
                rs1         : i_regs[i].rs1,
                rs2         : i_regs[i].rs2,
                func        : i_regs[i].func,
                cond_branch : i_regs[i].cond_branch,

                t           : i_regs[i].t,
                rob_idx     : i_regs[i].rob_idx,
                btq_idx     : i_regs[i].btq_idx
            };
        end
    end

    // execute
    generate
        CPL_CAND    [`NUM_FU_BRU-1:0] tmp_data;
        DATA        [`NUM_FU_BRU-1:0] tmp_res;
        logic       [`NUM_FU_BRU-1:0] cond_take, tmp_take;
        for (genvar i = 0; i < `NUM_FU_BRU; ++i) begin : gen_brus
            bru bru_0 ( 
                // Inputs
                .opa        (ops[i].opa),
                .opb        (ops[i].opb),
                .rs1        (ops[i].rs1),
                .rs2        (ops[i].rs2),
                .branch_func(ops[i].func),

                // Output (directly to cdat_out)
                .take       (cond_take[i]),
                .result     (tmp_res[i])
            );

            assign tmp_take[i] = !ops[i].cond_branch || cond_take[i];

            assign tmp_data[i] = '{
                t       : ops[i].t,
                rob_idx : ops[i].rob_idx,
                data    : tmp_take[i] ? npc_addrs[i] : tmp_res[i]
            };

            assign o_cands[i] = tmp_data[i];

            assign o_btq_out.dat[i] = '{
                en      : i_vld[i],
                btq_idx : ops[i].btq_idx,
                take    : tmp_take[i],
                tgt     : addr2w(tmp_res[i])
            };

        end
    endgenerate
endmodule

module stage_ex_p4 (
    input clock,
    input reset,
    input flush,

    input   rs2execute rs_in,
    output  execute2rs rs_out,

    input   dcache2ld   dcache_in,
    output  ld2dcache   dcache_out,

    input   prf2execute prf_in,
    output  execute2prf prf_out,

    output  execute2btq btq_out,

    output  execute2complete_tag ctag_out,
    output  execute2complete_dat cdat_out

);
    /* >> ======== STAGE 1: Issue Staging ======== >> */
    // (where just-issued insns wait for 1 cycle)
    struct packed {
        `BY_FU(logic)   i_rdy;
        `BY_FU(logic)   o_vld;
        struct packed {
            ID_ALU_VIEW [`NUM_FU_ALU-1:0]   alu;
            ID_MUL_VIEW [`NUM_FU_MUL-1:0]   mul;
            ID_LOD_VIEW [`NUM_FU_LOD-1:0]   lod;
            ID_STR_VIEW [`NUM_FU_STR-1:0]   str;
            ID_BRU_VIEW [`NUM_FU_BRU-1:0]   bru;
        } i_dat, o_dat;
    } iss;

    struct packed {
        `BY_FU(logic) i_rdy;
        `BY_FU(logic) o_vld;
        struct packed {
            ALU_REGS [`NUM_FU_ALU-1:0]  alu;
            MUL_REGS [`NUM_FU_MUL-1:0]  mul;
            LOD_REGS [`NUM_FU_LOD-1:0]  lod;
            STR_REGS [`NUM_FU_STR-1:0]  str;
            BRU_REGS [`NUM_FU_BRU-1:0]  bru;
        } i_dat, o_dat;
    } regs;
    
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
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alu_sbufs
            assign iss.i_dat.alu[i] = '{
                bytag   : rs_in.bytag_alu[i],
                t       : rs_in.fu_dat_alu[i].t,
                t1      : rs_in.fu_dat_alu[i].t1,
                t2      : rs_in.fu_dat_alu[i].t2,
                rob_idx : rs_in.fu_dat_alu[i].rob_idx,

                inst    : rs_in.fu_dat_alu[i].inst,
                PC      : rs_in.fu_dat_alu[i].PC,

                opa_select  : rs_in.fu_dat_alu[i].opa_select,
                opb_select  : rs_in.fu_dat_alu[i].opb_select,
                alu_func    : rs_in.fu_dat_alu[i].alu_func
            };

            assign iss.i_rdy.alu[i] = 1;
            flop #(
                .WIDTH($bits(ID_ALU_VIEW))
            ) sbuf_alu (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_alu[i]),
                .i_dat (iss.i_dat.alu[i]),

                .o_vld (iss.o_vld.alu[i]),
                .o_dat (iss.o_dat.alu[i])
            );
        end
        
        for (genvar i = 0; i < `NUM_FU_MUL; ++i) begin : gen_mul_sbufs
            assign iss.i_dat.mul[i] = '{
                t       : rs_in.fu_dat_mul[i].t,
                t1      : rs_in.fu_dat_mul[i].t1,
                t2      : rs_in.fu_dat_mul[i].t2,
                rob_idx : rs_in.fu_dat_mul[i].rob_idx,
                func    : rs_in.fu_dat_mul[i].func
            };

            ppln_skid #(
                .WIDTH($bits(ID_MUL_VIEW))
            ) sbuf_mul (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_mul[i]),
                .i_rdy (iss.i_rdy.mul[i]),
                .i_dat (iss.i_dat.mul[i]),

                .o_vld (iss.o_vld.mul[i]),
                .o_rdy (regs.i_rdy.mul[i]),
                .o_dat (iss.o_dat.mul[i])
            );
        end

        for (genvar i = 0; i < `NUM_FU_LOD; ++i) begin : gen_lod_sbufs
            assign iss.i_dat.lod[i] = '{
                t       : rs_in.fu_dat_lod[i].t,
                t1      : rs_in.fu_dat_lod[i].t1,
                opb     : `RV32_signext_Iimm(rs_in.fu_dat_lod[i].inst),

                // >> FIXME
                sq_idx  : '0,
                lq_idx  : '0,
                // << FIXME

                rob_idx : rs_in.fu_dat_lod[i].rob_idx,
                mem_size: MEM_SIZE'(rs_in.fu_dat_lod[i].inst.r.funct3[1:0]),
                rd_unsigned : rs_in.fu_dat_lod[i].inst.r.funct3[2]
            };

            ppln_skid #(
                .WIDTH($bits(ID_LOD_VIEW))
            ) sbuf_lod (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_lod[i]),
                .i_rdy (iss.i_rdy.lod[i]),
                .i_dat (iss.i_dat.lod[i]),

                .o_vld (iss.o_vld.lod[i]),
                .o_rdy (regs.i_rdy.lod[i]),
                .o_dat (iss.o_dat.lod[i])
            );
        end

        for (genvar i = 0; i < `NUM_FU_STR; ++i) begin : gen_str_sbufs
            assign iss.i_dat.str[i] = '{
                t1      : rs_in.fu_dat_str[i].t1,
                t2      : rs_in.fu_dat_str[i].t2,
                opb     : `RV32_signext_Simm(rs_in.fu_dat_str[i].inst),

                // >> FIXME
                sq_idx  : '0,
                // << FIXME

                rob_idx : rs_in.fu_dat_str[i].rob_idx,
                mem_size: MEM_SIZE'(rs_in.fu_dat_str[i].inst.r.funct3[1:0])
            };

            ppln_skid #(
                .WIDTH($bits(ID_STR_VIEW))
            ) sbuf_str (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_str[i]),
                .i_rdy (iss.i_rdy.str[i]),
                .i_dat (iss.i_dat.str[i]),

                .o_vld (iss.o_vld.str[i]),
                .o_rdy (regs.i_rdy.str[i]),
                .o_dat (iss.o_dat.str[i])
            );
        end

        for (genvar i = 0; i < `NUM_FU_BRU; ++i) begin : gen_bru_sbufs
            assign iss.i_dat.bru[i] = '{
                bytag   : rs_in.bytag_bru[i],
                t       : rs_in.fu_dat_bru[i].t,
                t1      : rs_in.fu_dat_bru[i].t1,
                t2      : rs_in.fu_dat_bru[i].t2,
                rob_idx : rs_in.fu_dat_bru[i].rob_idx,
                btq_idx : rs_in.fu_dat_bru[i].btq_idx,

                inst    : rs_in.fu_dat_bru[i].inst,
                PC      : rs_in.fu_dat_bru[i].PC,

                opa_select  : rs_in.fu_dat_bru[i].opa_select,
                opb_select  : rs_in.fu_dat_bru[i].opb_select,
                cond_branch : rs_in.fu_dat_bru[i].cond_branch
            };

            assign iss.i_rdy.bru[i] = 1;
            flop #(
                .WIDTH($bits(ID_BRU_VIEW))
            ) sbuf_bru (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_bru[i]),
                .i_dat (iss.i_dat.bru[i]),

                .o_vld (iss.o_vld.bru[i]),
                .o_dat (iss.o_dat.bru[i])
            );
        end
    endgenerate

    /* >> ======== STAGE 2: PRF Read ======== >> */
    // fetch rs1, rs2 from PRF **IF NOT BYPASSING**
    always_comb begin
        prf_out = '0;
        foreach (iss.o_vld.alu[i]) begin
            prf_out.en1s.alu[i]   = iss.o_vld.alu[i];
            prf_out.en2s.alu[i]   = iss.o_vld.alu[i];
            prf_out.t1s.alu[i]    = iss.o_dat.alu[i].t1; 
            prf_out.t2s.alu[i]    = iss.o_dat.alu[i].t2; 
        end
        foreach (iss.o_vld.mul[i]) begin
            prf_out.en1s.mul[i]   = iss.o_vld.mul[i];
            prf_out.en2s.mul[i]   = iss.o_vld.mul[i];
            prf_out.t1s.mul[i]    = iss.o_dat.mul[i].t1; 
            prf_out.t2s.mul[i]    = iss.o_dat.mul[i].t2; 
        end
        foreach (iss.o_vld.lod[i]) begin
            prf_out.en1s.lod[i]   = iss.o_vld.lod[i];
            prf_out.t1s.lod[i]    = iss.o_dat.lod[i].t1; 
        end
        foreach (iss.o_vld.str[i]) begin
            prf_out.en1s.str[i]   = iss.o_vld.str[i];
            prf_out.en2s.str[i]   = iss.o_vld.str[i];
            prf_out.t1s.str[i]    = iss.o_dat.str[i].t1; 
            prf_out.t2s.str[i]    = iss.o_dat.str[i].t2; 
        end
        foreach (iss.o_vld.bru[i]) begin
            prf_out.en1s.bru[i]   = iss.o_vld.bru[i];
            prf_out.en2s.bru[i]   = iss.o_vld.bru[i];
            prf_out.t1s.bru[i]    = iss.o_dat.bru[i].t1; 
            prf_out.t2s.bru[i]    = iss.o_dat.bru[i].t2; 
        end
    end

    struct packed {
        `BY_FU(logic) i_rdy;
    } ex;
    always_comb begin
        foreach (iss.o_vld.alu[i]) begin
            DATA imm32b;
            logic opb_is_rs2;

            opb_is_rs2 = iss.o_dat.alu[i].opb_select == OPB_IS_RS2;
            case (iss.o_dat.alu[i].opb_select)
                OPB_IS_RS2:   imm32b =  '0;
                OPB_IS_I_IMM: imm32b = `RV32_signext_Iimm(iss.o_dat.alu[i].inst);
                OPB_IS_S_IMM: imm32b = `RV32_signext_Simm(iss.o_dat.alu[i].inst);
                OPB_IS_B_IMM: imm32b = `RV32_signext_Bimm(iss.o_dat.alu[i].inst);
                OPB_IS_U_IMM: imm32b = `RV32_signext_Uimm(iss.o_dat.alu[i].inst);
                OPB_IS_J_IMM: imm32b = `RV32_signext_Jimm(iss.o_dat.alu[i].inst);
                default:      imm32b = 32'hfacefeed; // face feed
            endcase

            regs.i_dat.alu[i] = '{
                bytag : iss.o_dat.alu[i].bytag,
                rs1 : prf_in.v1s.alu[i],
                opb : opb_is_rs2
                    ? prf_in.v2s.alu[i]
                    : imm32b,

                PC          : iss.o_dat.alu[i].PC,
                opa_select  : iss.o_dat.alu[i].opa_select,
                opb_is_rs2  : opb_is_rs2,
                alu_func    : iss.o_dat.alu[i].alu_func,

                t           : iss.o_dat.alu[i].t,
                rob_idx     : iss.o_dat.alu[i].rob_idx
            };
        end
        foreach (iss.o_vld.mul[i]) begin
            regs.i_dat.mul[i] = '{
                rs1 : prf_in.v1s.mul[i],
                rs2 : prf_in.v2s.mul[i],
                t1  : iss.o_dat.mul[i].t1,
                t2  : iss.o_dat.mul[i].t2,

                func    : iss.o_dat.mul[i].func,

                t       : iss.o_dat.mul[i].t,
                rob_idx : iss.o_dat.mul[i].rob_idx
            };
        end
        foreach (iss.o_vld.lod[i]) begin
            regs.i_dat.lod[i] = '{
                rs1 : prf_in.v1s.lod[i],
                dat : iss.o_dat.lod[i]
            };
        end
        foreach (iss.o_vld.str[i]) begin
            regs.i_dat.str[i] = '{
                rs1 : prf_in.v1s.str[i],
                rs2 : prf_in.v2s.str[i],
                dat : iss.o_dat.str[i]
            };
        end
        foreach (iss.o_vld.bru[i]) begin
            DATA imm32b;
            case (iss.o_dat.bru[i].opb_select)
                OPB_IS_I_IMM: imm32b = `RV32_signext_Iimm(iss.o_dat.bru[i].inst);
                OPB_IS_B_IMM: imm32b = `RV32_signext_Bimm(iss.o_dat.bru[i].inst);
                OPB_IS_J_IMM: imm32b = `RV32_signext_Jimm(iss.o_dat.bru[i].inst);
                default:      imm32b = 32'hfacefeed; // face feed
            endcase

            regs.i_dat.bru[i] = '{
                bytag : iss.o_dat.bru[i].bytag,
                rs1 : prf_in.v1s.bru[i],
                rs2 : prf_in.v2s.bru[i],

                PC          : iss.o_dat.bru[i].PC,
                opa_select  : iss.o_dat.bru[i].opa_select,
                opb_is_rs2  : iss.o_dat.bru[i].opb_select == OPB_IS_RS2,
                imm32b      : imm32b,
                func        : iss.o_dat.bru[i].inst.b.funct3,
                cond_branch : iss.o_dat.bru[i].cond_branch,

                t           : iss.o_dat.bru[i].t,
                rob_idx     : iss.o_dat.bru[i].rob_idx,
                btq_idx     : iss.o_dat.bru[i].btq_idx
            };
        end
    end

    generate
        assign regs.i_rdy.alu = '1;
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alu_rbufs
            /* Unlike mul, lod, str, we *shouldn't* need snooping to feed back
            into rbuf (via i_snoop) because we *should* never stall post issue. */
            ALU_REGS raw;
            flop #(
                .WIDTH($bits(ALU_REGS))
            ) rbuf_alu (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (iss.o_vld.alu[i]),
                .i_dat (regs.i_dat.alu[i]),

                .o_vld (regs.o_vld.alu[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.alu[i] = alu_snoop(raw, cdat_out);
        end

        for (genvar i = 0; i < `NUM_FU_MUL; ++i) begin : gen_mul_rbufs
            /* Even if we are stalled, we must snoop the CDB to make sure
            we don't miss the 1 cycle bypass window. */
            MUL_REGS raw;
            skid #(
                .ENABLE_SNOOP(`TRUE),
                .WIDTH($bits(MUL_REGS))
            ) rbuf_mul (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_snoop(regs.o_dat.mul[i]),

                .i_vld (iss.o_vld.mul[i]),
                .i_rdy (regs.i_rdy.mul[i]),
                .i_dat (regs.i_dat.mul[i]),

                .o_vld (regs.o_vld.mul[i]),
                .o_rdy (ex.i_rdy.mul[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.mul[i] = mul_snoop(raw, cdat_out);
        end

        for (genvar i = 0; i < `NUM_FU_LOD; ++i) begin : gen_lod_rbufs
            LOD_REGS raw;
            skid #(
                .ENABLE_SNOOP(`TRUE),
                .WIDTH($bits(LOD_REGS))
            ) rbuf_lod (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_snoop(regs.o_dat.lod[i]),

                .i_vld (iss.o_vld.lod[i]),
                .i_rdy (regs.i_rdy.lod[i]),
                .i_dat (regs.i_dat.lod[i]),

                .o_vld (regs.o_vld.lod[i]),
                .o_rdy (ex.i_rdy.lod[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.lod[i] = lod_snoop(raw, cdat_out);
        end

        for (genvar i = 0; i < `NUM_FU_STR; ++i) begin : gen_str_rbufs
            STR_REGS raw;
            skid #(
                .ENABLE_SNOOP(`TRUE),
                .WIDTH($bits(STR_REGS))
            ) rbuf_str (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_snoop(regs.o_dat.str[i]),

                .i_vld (iss.o_vld.str[i]),
                .i_rdy (regs.i_rdy.str[i]),
                .i_dat (regs.i_dat.str[i]),

                .o_vld (regs.o_vld.str[i]),
                .o_rdy (ex.i_rdy.str[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.str[i] = str_snoop(raw, cdat_out);
        end

        assign regs.i_rdy.bru = '1;
        for (genvar i = 0; i < `NUM_FU_BRU; ++i) begin : gen_bru_rbufs
            /* Unlike mul, lod, str, we *shouldn't* need snooping to feed back
            into rbuf (via i_snoop) because we *should* never stall post issue. */
            BRU_REGS raw;
            flop #(
                .WIDTH($bits(BRU_REGS))
            ) rbuf_bru (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (iss.o_vld.bru[i]),
                .i_dat (regs.i_dat.bru[i]),

                .o_vld (regs.o_vld.bru[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.bru[i] = bru_snoop(raw, cdat_out);
        end
    endgenerate

    /* >> ======== STAGE ?: (early) CDB arbitration ======== >> */
    // If 1-cycle operation (e.g. ALU), this is before issue staging.
    // Else if a longer-latency insn, this is in the middle of execution.

    `BY_FU(CPL_CAND) cands;
    assign cands.str = '0; // alu, mul, lod set by respective *_ex's
    CPL_CAND [`NUM_FU_TOTAL-1:0] cands_flat;
    assign cands_flat = cands;

    /*
    Complete grant bus shift register
    */
    logic [1:0][`N-1:0][`NUM_FU_TOTAL-1:0]  cdb2fu_gbus_shr;
    logic [`N-1:0][`NUM_FU_TOTAL-1:0]       cdb2fu_gbus;
    `BY_FU(logic) [1:0] cdb_gnt_shr;

    `BY_FU(logic) cdb_req;
    assign cdb_req.alu = rs_in.fu_vld_alu;
    // cdb_req.mul set by mul_ex
    // cdb_req.lod set by lod_ex
    assign cdb_req.lod = '0; // FIXME
    assign cdb_req.str = '0;
    assign cdb_req.bru = rs_in.fu_vld_bru;
    `BY_FU(logic) cdb_gnt;

    psel_gen #(
        .WIDTH(`NUM_FU_TOTAL),
        .REQS(`N)
    ) cdb_arb (
        .req    (cdb_req),  // flatten (alu + mul bits) => single [NUM_FU_TOTAL-1:0] bus
        .gnt    (cdb_gnt),  // flatten => single bus
        .gnt_bus(cdb2fu_gbus)
    );

    /* >> ======== STAGE 3: Execution ======== >> */
    // Includes operand decode/CDB bypass just before 1st cycle of execution.

    alu_ex alu_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .i_vld  (regs.o_vld.alu),
        .i_regs (regs.o_dat.alu),

        .o_cands(cands.alu)
    );

    `BY_FU(PHYS_REG_IDX) ctag_ts;
    PHYS_REG_IDX [`NUM_FU_TOTAL-1:0] ctag_ts_flat;

    mul_ex mul_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .i_vld  (regs.o_vld.mul),
        .i_regs (regs.o_dat.mul),
        .i_rdy  (ex.i_rdy.mul),

        .cdb_req(cdb_req.mul),
        .ctag_ts(ctag_ts.mul),
        .cdb_gnt(cdb_gnt.mul),

        .o_cands(cands.mul)
    );

    execute2btq btq_out_n;
    bru_ex bru_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .i_vld  (regs.o_vld.bru),
        .i_regs (regs.o_dat.bru),

        .o_btq_out(btq_out_n),
        .o_cands(cands.bru)
    );

    /* >> ======== STAGE 4/?: CDB data/tag broadcast ======== >> */
    // Tag broadcast occurs with CDB arbitration
    // Data broadcast is the final stage of the execute pipeline.
    execute2complete_tag ctag_out_n;
    execute2complete_dat cdat_out_n;
    always_comb begin
        rs_out = '{
            fu_cdb_gnt_alu  : cdb_gnt.alu,
            fu_cdb_gnt_bru  : cdb_gnt.bru,

            fu_rdy_alu      : iss.i_rdy.alu,
            fu_rdy_mul      : iss.i_rdy.mul,
            fu_rdy_lod      : iss.i_rdy.lod,
            fu_rdy_str      : iss.i_rdy.str,
            fu_rdy_bru      : iss.i_rdy.bru
        };

        foreach (rs_in.fu_dat_alu[i])
            ctag_ts.alu[i] = rs_in.fu_dat_alu[i].t;
        foreach (rs_in.fu_dat_bru[i])
            ctag_ts.bru[i] = rs_in.fu_dat_bru[i].t;
        ctag_ts_flat = ctag_ts;

        ctag_out_n = '0;
        cdat_out_n = '0;
        foreach(cdb2fu_gbus_shr[_, c, f]) begin
            if (cdb2fu_gbus[c][f]) begin
                ctag_out_n.en[c]  |= 1;
                ctag_out_n.ts[c]  |= ctag_ts_flat[f];
            end

            if (cdb2fu_gbus_shr[1][c][f]) begin
                cdat_out_n.en[c]        |= 1;
                cdat_out_n.ts[c]        |= cands_flat[f].t;
                cdat_out_n.rob_idxs[c]  |= cands_flat[f].rob_idx;
                cdat_out_n.data[c]      |= cands_flat[f].data;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            cdb2fu_gbus_shr <= '0;
            cdb_gnt_shr     <= '0;
            ctag_out        <= '0;
            cdat_out        <= '0;
            btq_out         <= '0;
        end else begin
            cdb2fu_gbus_shr[0]  <= cdb2fu_gbus;
            cdb_gnt_shr[0]      <= cdb_gnt;
            for (int unsigned i = 0; i < 1; ++i) begin
                cdb2fu_gbus_shr[i+1] <= cdb2fu_gbus_shr[i];
                cdb_gnt_shr[i+1]     <= cdb_gnt_shr[i];
            end
            ctag_out <= ctag_out_n;
            cdat_out <= cdat_out_n;
            btq_out  <= btq_out_n;

            if (ctag_out.en[0] && ctag_out.en[1]
                && ctag_out.ts[0] == ctag_out.ts[1]
                && ctag_out.ts[0] != '0) begin
                $error("💥 DUPLICATE CDB_TAG TAG: slot %0d and %0d both write tag %0d", 0, 1, ctag_out.ts[1]);
            end
            if (cdat_out.en[0] && cdat_out.en[1]
                && cdat_out.ts[0] == cdat_out.ts[1]
                && cdat_out.ts[0] != '0) begin
                $error("💥 DUPLICATE CDB_DAT tag: slot %0d and %0d both write tag %0d", 0, 1, cdat_out.ts[1]);
            end
        end
    end

`ifdef DEBUG
    task print_execute();
        $display("  %3d | >> EXECUTE", $time);

        for (int i = 0; i < `NUM_FU_ALU; ++i) begin
            $display("alu_iss[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, inst: 0x%x, PC: 0x%x",
                i,
                iss.i_rdy.alu[i],
                iss.o_vld.alu[i],
                iss.o_dat.alu[i].t,
                iss.o_dat.alu[i].t1,
                iss.o_dat.alu[i].t2,
                iss.o_dat.alu[i].rob_idx,
                iss.o_dat.alu[i].inst,
                iss.o_dat.alu[i].PC
            );
        end

        for (int i = 0; i < `NUM_FU_MUL; ++i) begin
            $display("mul_iss[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, func: 0x%x",
                i,
                iss.i_rdy.mul[i],
                iss.o_vld.mul[i],
                iss.o_dat.mul[i].t,
                iss.o_dat.mul[i].t1,
                iss.o_dat.mul[i].t2,
                iss.o_dat.mul[i].rob_idx,
                iss.o_dat.mul[i].func
            );
        end

        for (int i = 0; i < `NUM_FU_ALU; ++i) begin
            $display("regs.o_dat.alu[%0d]: bsy: %b, rs1: 0x%x, opb: 0x%x t: %2d, rob_idx: %2d",
                i,
                regs.o_vld.alu[i],
                regs.o_dat.alu[i].rs1,
                regs.o_dat.alu[i].opb,
                regs.o_dat.alu[i].t,
                regs.o_dat.alu[i].rob_idx
            );
        end

        for (int i = 0; i < `NUM_FU_MUL; ++i) begin
            $display("regs.o_dat.mul[%0d]: bsy: %b, rs1: 0x%x, rs2: 0x%x t: %2d, rob_idx: %2d",
                i,
                regs.o_vld.mul[i],
                regs.o_dat.mul[i].rs1,
                regs.o_dat.mul[i].rs2,
                regs.o_dat.mul[i].t,
                regs.o_dat.mul[i].rob_idx
            );
        end

        // $display("c_out: rdy_alu:{%b} rdy_mult:{%b} rdy_store:{%b} rdy_load:{%b}",
        //     rs_out.fu_rdy_alu,
        //     rs_out.fu_rdy_mul,
        //     rs_out.fu_rdy_str,
        //     rs_out.fu_rdy_lod,
        // );

        $display("\ncdb_req: alu:{%b} mul:{%b} lod:{%b} str:{%b}", cdb_req.alu, cdb_req.mul, cdb_req.lod, cdb_req.str);
        $display("\nctag_ts: alu:{%b} mul:{%b} lod:{%b} str:{%b}", ctag_ts.alu, ctag_ts.mul, ctag_ts.lod, ctag_ts.str);
        // $display("ctag_ts: alu:{%2d, %2d} mul:{%2d, %2d}",
        //     ctag_ts.alu[1], ctag_ts.alu[0], ctag_ts.mul[1], ctag_ts.mul[0]);
        $display("cdb_gnt: alu:{%b} mul:{%b}", cdb_gnt.alu, cdb_gnt.mul);
        for (int i = 0; i < 2; ++i) begin
            $display("cdb_gnt[%0d]: alu:{%b} mul:{%b} lod:{%b} str:{%b}",
                i,
                cdb_gnt_shr[i].alu,
                cdb_gnt_shr[i].mul,
                cdb_gnt_shr[i].lod,
                cdb_gnt_shr[i].str
            );
        end

        $display("");
        for (int n = 0; n < `N; ++n) begin
            $display("cdb2fu_gbus[%0d]: %b", n, cdb2fu_gbus[n]);
        end
        for (int s = 0; s < 2; ++s) begin
            for (int n = 0; n < `N; ++n) begin
                $display("cdb2fu_gbus[%0d][%0d]: %b", s, n, cdb2fu_gbus_shr[s][n]);
            end
        end

        for (int i = 0; i < `N; ++i) begin
            $display("ctag_out[%0d]: en: %b, ts: %2d",
                i,
                ctag_out.en[i],
                ctag_out.ts[i],
            );
        end
        for (int i = 0; i < `N; ++i) begin
            $display("cdat_out[%0d]: en: %b,  ts: %2d, rob_idxs: %2d, data: %x",
                i,
                cdat_out.en[i],
                cdat_out.ts[i],
                cdat_out.rob_idxs[i],
                cdat_out.data[i]
            );
        end

        $display("  %3d | << EXECUTE", $time);
    endtask
`endif

endmodule // stage_ex
