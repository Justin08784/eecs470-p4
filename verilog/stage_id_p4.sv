
// The decoder, copied from project 3

// This has a few changes, it now sets a "mult" flag for multiply instructions
// Pass these to the mult module with inst.r.funct3 as the MULT_FUNC

`include "sys_defs.svh"
`include "ISA.svh"

// Decode an instruction: generate useful datapath control signals by matching the RISC-V ISA
// This module is purely combinational
module decoder_p4 (
    input INST  inst,
    input logic valid, // when low, ignore inst. Output will look like a NOP

    output FU_IDX         fu_idx,
    output ALU_OPA_SELECT opa_select,
    output ALU_OPB_SELECT opb_select,
    output logic          has_dest, // if there is a destination register
    output ALU_FUNC       alu_func,
    output logic          mult, rd_mem, wr_mem, cond_branch, uncond_branch,
    output logic          csr_op, // used for CSR operations, we only use this as a cheap way to get the return code out
    output logic          halt,   // non-zero on a halt
    output logic          illegal // non-zero on an illegal instruction
);

    // Note: I recommend using an IDE's code folding feature on this block
    always_comb begin
        // Default control values (looks like a NOP)
        // See sys_defs.svh for the constants used here
        fu_idx        = 0;
        opa_select    = OPA_IS_RS1;
        opb_select    = OPB_IS_RS2;
        alu_func      = ALU_ADD;
        has_dest      = `FALSE;
        csr_op        = `FALSE;
        mult          = `FALSE;
        rd_mem        = `FALSE;
        wr_mem        = `FALSE;
        cond_branch   = `FALSE;
        uncond_branch = `FALSE;
        halt          = `FALSE;
        illegal       = `FALSE;

        if (valid) begin
            casez (inst)
                `RV32_LUI: begin
                    has_dest   = `TRUE;
                    opa_select = OPA_IS_ZERO;
                    opb_select = OPB_IS_U_IMM;
                end
                `RV32_AUIPC: begin
                    has_dest   = `TRUE;
                    opa_select = OPA_IS_PC;
                    opb_select = OPB_IS_U_IMM;
                end
                `RV32_JAL: begin
                    has_dest      = `TRUE;
                    opa_select    = OPA_IS_PC;
                    opb_select    = OPB_IS_J_IMM;
                    uncond_branch = `TRUE;
                end
                `RV32_JALR: begin
                    has_dest      = `TRUE;
                    opa_select    = OPA_IS_RS1;
                    opb_select    = OPB_IS_I_IMM;
                    uncond_branch = `TRUE;
                end
                `RV32_BEQ, `RV32_BNE, `RV32_BLT, `RV32_BGE,
                `RV32_BLTU, `RV32_BGEU: begin
                    opa_select  = OPA_IS_PC;
                    opb_select  = OPB_IS_B_IMM;
                    cond_branch = `TRUE;
                    // stage_ex uses inst.b.funct3 as the branch function
                end
                `RV32_MUL, `RV32_MULH, `RV32_MULHSU, `RV32_MULHU: begin
                    fu_idx     = FU_MULT;
                    has_dest   = `TRUE;
                    mult       = `TRUE;
                    // stage_ex uses inst.r.funct3 as the mult function
                end
                `RV32_LB, `RV32_LH, `RV32_LW,
                `RV32_LBU, `RV32_LHU: begin
                    fu_idx     = FU_LOAD;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    rd_mem     = `TRUE;
                    // stage_ex uses inst.r.funct3 as the load size and signedness
                end
                `RV32_SB, `RV32_SH, `RV32_SW: begin
                    fu_idx     = FU_STORE;
                    opb_select = OPB_IS_S_IMM;
                    wr_mem     = `TRUE;
                    // stage_ex uses inst.r.funct3 as the store size
                end
                `RV32_ADDI: begin
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                end
                `RV32_SLTI: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SLT;
                end
                `RV32_SLTIU: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SLTU;
                end
                `RV32_ANDI: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_AND;
                end
                `RV32_ORI: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_OR;
                end
                `RV32_XORI: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_XOR;
                end
                `RV32_SLLI: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SLL;
                end
                `RV32_SRLI: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SRL;
                end
                `RV32_SRAI: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    opb_select = OPB_IS_I_IMM;
                    alu_func   = ALU_SRA;
                end
                `RV32_ADD: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                end
                `RV32_SUB: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_SUB;
                end
                `RV32_SLT: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_SLT;
                end
                `RV32_SLTU: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_SLTU;
                end
                `RV32_AND: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_AND;
                end
                `RV32_OR: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_OR;
                end
                `RV32_XOR: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_XOR;
                end
                `RV32_SLL: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_SLL;
                end
                `RV32_SRL: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_SRL;
                end
                `RV32_SRA: begin
                    fu_idx     = FU_ALU;
                    has_dest   = `TRUE;
                    alu_func   = ALU_SRA;
                end
                `RV32_CSRRW, `RV32_CSRRS, `RV32_CSRRC: begin
                    csr_op = `TRUE;
                end
                `WFI: begin
                    halt = `TRUE;
                end
                default: begin
                    illegal = `TRUE;
                end
        endcase // casez (inst)
        end // if (valid)
    end // always

endmodule // decoder


module stage_id_p4 (
    input              clock,           // system clock
    input              reset,           // system reset

    input IF_ID_PACKET [`N-1:0] if_id_reg,
    input logic [$clog2(`N):0]  en_cnt,

    input   dispatch2decode d_in,
    output  decode2dispatch d_out
    // output ID_EX_PACKET id_packet
);


    // assign d_out.d_dat[0].valid = if_id_reg[0].valid;
    assign d_out.d_en_cnt = en_cnt;

    logic [`N-1:0] has_dest_reg;
    int insn_id;

    ID_RESULT [`N-1:0] tmp;

    // Instantiate the instruction decoder
    generate
    for (genvar i = 0; i < `N; ++i) begin : gen_decoders
        decoder_p4 decoder_i (
            // Inputs
            .inst  (if_id_reg[i].inst),
            .valid (if_id_reg[i].valid),

            // Outputs
            .opa_select    (tmp[i].opa_select),
            .opb_select    (tmp[i].opb_select),
            .alu_func      (tmp[i].alu_func),
            .has_dest      (has_dest_reg[i]),
            .mult          (tmp[i].mult),
            .rd_mem        (tmp[i].rd_mem),
            .wr_mem        (tmp[i].wr_mem),
            .cond_branch   (tmp[i].cond_branch),
            .uncond_branch (tmp[i].uncond_branch),
            .csr_op        (tmp[i].csr_op),
            .halt          (tmp[i].halt),
            .illegal       (tmp[i].illegal)
        );
    end
    endgenerate

    always_comb begin
        for (int unsigned i = 0; i < `N; ++i) begin
            tmp[i].inst = if_id_reg[i].inst;
            tmp[i].PC   = if_id_reg[i].PC;
            tmp[i].NPC  = if_id_reg[i].NPC;
            tmp[i].id   = insn_id + i;

            tmp[i].dest_reg_idx = (has_dest_reg[i]) ? if_id_reg[i].inst.r.rd : `ZERO_REG;
        end
    end


    fifo #(
        .DEPTH(`N),
        .WIDTH($bits(ID_RESULT)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N)
    ) id_buf(
        .clock      (clock),
        .reset      (reset),
        .wr_en_cnt  (en_cnt),
        .wr_data    (tmp),
        .rd_en_cnt  (d_in.dispatch_rdy_cnt),
        .rd_data    (d_out.d_dat),
        .free_scnt  (),
        .used_scnt  ()
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            insn_id <= 0;
        end else begin
            insn_id <= insn_id + en_cnt;
        end
    end

endmodule // stage_id

