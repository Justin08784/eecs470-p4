
// The decoder, copied from project 3

// This has a few changes, it now sets a "mult" flag for multiply instructions
// Pass these to the mult module with inst.r.funct3 as the MULT_FUNC

`include "sys_defs.svh"
`include "ISA.svh"

// Decode an instruction: generate useful datapath control signals by matching the RISC-V ISA
// This module is purely combinational
module decoder (
    input clock,
    input reset,
    input IF_ID_PACKET [`N-1:0] if_id_reg,
    input logic [$clog2(`N):0] valid, // when low, ignore inst. Output will look like a NOP

    // output ALU_OPA_SELECT [N-1:0] opa_select,
    // output ALU_OPB_SELECT [N-1:0] opb_select,
    // output logic          [N-1:0] has_dest, // if there is a destination register
    // output ALU_FUNC       [N-1:0] alu_func,
    // output logic          [N-1:0] mult, rd_mem, wr_mem, cond_branch, uncond_branch,
    // output logic          [N-1:0] csr_op, // used for CSR operations, we only use this as a cheap way to get the return code out
    // output logic          [N-1:0] halt,   // non-zero on a halt
    // output logic          [N-1:0] illegal // non-zero on an illegal instruction

    output ID_RESULT      [`N-1:0] decode_out,
    output logic   [$clog2(`N):0] valid_out
);

    ID_RESULT      [`N-1:0] decode_out_n;
    int id;
    // logic [`N-1:0] has_dest;

    always_ff @(posedge clock) begin
        if(reset) begin
            id <= 0;
        end else begin
            id <= id + valid;
        end
    end
    // Note: I recommend using an IDE's code folding feature on this block
    always_comb begin
        for(int i = 0; i < valid; ++i) begin

            // Default control values (looks like a NOP)
            // See sys_defs.svh for the constants used here
            decode_out_n[i].inst          = if_id_reg[i].inst;
            decode_out_n[i].PC            = if_id_reg[i].PC;
            decode_out_n[i].NPC           = if_id_reg[i].NPC;
            decode_out_n[i].fu_idx        = '0;
            decode_out_n[i].opa_select    = OPA_IS_RS1;
            decode_out_n[i].opb_select    = OPB_IS_RS2;
            decode_out_n[i].alu_func      = ALU_ADD;
            decode_out_n[i].csr_op        = `FALSE;
            decode_out_n[i].mult          = `FALSE;
            decode_out_n[i].rd_mem        = `FALSE;
            decode_out_n[i].wr_mem        = `FALSE;
            decode_out_n[i].cond_branch   = `FALSE;
            decode_out_n[i].uncond_branch = `FALSE;
            decode_out_n[i].halt          = `FALSE;
            decode_out_n[i].illegal       = `FALSE;
            decode_out_n[i].dest_reg_idx  = `ZERO_REG;

                casez (if_id_reg[i].inst)
                    `RV32_LUI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opa_select = OPA_IS_ZERO;
                        decode_out_n[i].opb_select = OPB_IS_U_IMM;
                    end
                    `RV32_AUIPC: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opa_select = OPA_IS_PC;
                        decode_out_n[i].opb_select = OPB_IS_U_IMM;
                    end
                    `RV32_JAL: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opa_select    = OPA_IS_PC;
                        decode_out_n[i].opb_select    = OPB_IS_J_IMM;
                        decode_out_n[i].uncond_branch = `TRUE;
                    end
                    `RV32_JALR: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opa_select    = OPA_IS_RS1;
                        decode_out_n[i].opb_select    = OPB_IS_I_IMM;
                        decode_out_n[i].uncond_branch = `TRUE;
                    end
                    `RV32_BEQ, `RV32_BNE, `RV32_BLT, `RV32_BGE,
                    `RV32_BLTU, `RV32_BGEU: begin
                        decode_out_n[i].opa_select  = OPA_IS_PC;
                        decode_out_n[i].opb_select  = OPB_IS_B_IMM;
                        decode_out_n[i].cond_branch = `TRUE;
                        // stage_ex uses inst.b.funct3 as the branch function
                    end
                    `RV32_MUL, `RV32_MULH, `RV32_MULHSU, `RV32_MULHU: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].mult       = `TRUE;
                        decode_out_n[i].fu_idx     = 2'b01;
                        // stage_ex uses inst.r.funct3 as the mult function
                    end
                    `RV32_LB, `RV32_LH, `RV32_LW,
                    `RV32_LBU, `RV32_LHU: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].rd_mem     = `TRUE;
                        decode_out_n[i].fu_idx     = 2'b10;
                        // stage_ex uses inst.r.funct3 as the load size and signedness
                    end
                    `RV32_SB, `RV32_SH, `RV32_SW: begin
                        decode_out_n[i].opb_select = OPB_IS_S_IMM;
                        decode_out_n[i].wr_mem     = `TRUE;
                        decode_out_n[i].fu_idx     = 2'b11;
                        // stage_ex uses inst.r.funct3 as the store size
                    end
                    `RV32_ADDI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                    end
                    `RV32_SLTI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].alu_func   = ALU_SLT;
                    end
                    `RV32_SLTIU: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].alu_func   = ALU_SLTU;
                    end
                    `RV32_ANDI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].alu_func   = ALU_AND;
                    end
                    `RV32_ORI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].alu_func   = ALU_OR;
                    end
                    `RV32_XORI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].alu_func   = ALU_XOR;
                    end
                    `RV32_SLLI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].alu_func   = ALU_SLL;
                    end
                    `RV32_SRLI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].alu_func   = ALU_SRL;
                    end
                    `RV32_SRAI: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].opb_select = OPB_IS_I_IMM;
                        decode_out_n[i].alu_func   = ALU_SRA;
                    end
                    `RV32_ADD: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                    end
                    `RV32_SUB: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_SUB;
                    end
                    `RV32_SLT: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_SLT;
                    end
                    `RV32_SLTU: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_SLTU;
                    end
                    `RV32_AND: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_AND;
                    end
                    `RV32_OR: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_OR;
                    end
                    `RV32_XOR: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_XOR;
                    end
                    `RV32_SLL: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_SLL;
                    end
                    `RV32_SRL: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_SRL;
                    end
                    `RV32_SRA: begin
                        decode_out_n[i].dest_reg_idx = if_id_reg[i].inst.r.rd;
                        decode_out_n[i].alu_func   = ALU_SRA;
                    end
                    `RV32_CSRRW, `RV32_CSRRS, `RV32_CSRRC: begin
                        decode_out_n[i].csr_op = `TRUE;
                    end
                    `WFI: begin
                        decode_out_n[i].halt = `TRUE;
                    end
                    default: begin
                        decode_out_n[i].illegal = `TRUE;
                    end
            endcase // casez (inst)
            // assign decode_out_n[i].dest_reg_idx = (has_dest[i]) ? if_id_reg[i].inst.r.rd : `ZERO_REG;
        end
    end // always

    always_ff @(posedge clock) begin
        if (reset) begin
            decode_out <= '0;
        end else if (valid == `N) begin
            decode_out <= decode_out_n;
        end else if (valid == 0) begin
            decode_out <= decode_out;
        end else begin
            decode_out[`N-1] <= decode_out_n[0];
            decode_out[`N-2:0] <= decode_out[`N-1:1];
        end
    end

    assign valid_out = valid;

endmodule // decoder
