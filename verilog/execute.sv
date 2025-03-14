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

// ALU: computes the result of FUNC applied with operands A and B
// This module is purely combinational
module alu (
    input DATA     opa,
    input DATA     opb,
    input ALU_FUNC alu_func,

    output DATA result
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

// Conditional branch module: compute whether to take conditional branches
// This module is purely combinational
module conditional_branch (
    input DATA  rs1,
    input DATA  rs2,
    input [2:0] func, // Which branch condition to check

    output logic take // True/False condition result
);

    always_comb begin
        case (func)
            3'b000:  take = signed'(rs1) == signed'(rs2); // BEQ
            3'b001:  take = signed'(rs1) != signed'(rs2); // BNE
            3'b100:  take = signed'(rs1) <  signed'(rs2); // BLT
            3'b101:  take = signed'(rs1) >= signed'(rs2); // BGE
            3'b110:  take = rs1 < rs2;                    // BLTU
            3'b111:  take = rs1 >= rs2;                   // BGEU
            default: take = `FALSE;
        endcase
    end

endmodule // conditional_branch

// module mult_no_pipeline (
//     input clock, reset, start,
//     input DATA rs1, rs2,
//     input MULT_FUNC func,

//     output DATA  result,
//     output logic done
// );

//     logic [63:0] mcand, mplier, product;

//     assign product = mcand * mplier;

//     // Sign-extend the multiplier inputs based on the operation
//     always_comb begin
//         case (func)
//             M_MUL, M_MULH, M_MULHSU: mcand = {{(32){rs1[31]}}, rs1};
//             default:                 mcand = {32'b0, rs1};
//         endcase
//         case (func)
//             M_MUL, M_MULH: mplier = {{(32){rs2[31]}}, rs2};
//             default:       mplier = {32'b0, rs2};
//         endcase
//     end

//     // Use the high or low bits of the product based on the output func
//     assign result = (func == M_MUL) ? product[31:0] : product[63:32];

// endmodule



module stage_ex (
    input   logic       [NUM_FU_ALU-1:0]    fu_vld_alu,
    input   logic       [NUM_FU_MULT-1:0]   fu_vld_mult,
    input   logic       [NUM_FU_STORE-1:0]  fu_vld_store,
    input   logic       [NUM_FU_LOAD-1:0]   fu_vld_load,
    input   ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu,
    input   ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult,
    input   ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store,
    input   ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load,

    output  logic       [NUM_FU_ALU-1:0]    fu_rdy_alu,
    output  logic       [NUM_FU_MULT-1:0]   fu_rdy_mult,
    output  logic       [NUM_FU_STORE-1:0]  fu_rdy_store,
    output  logic       [NUM_FU_LOAD-1:0]   fu_rdy_load,


);

    DATA alu_result, mult_result, opa_mux_out, opb_mux_out;
    logic take_conditional;
    logic mult_done;

    // Pass-throughs
    assign ex_packet.NPC          = id_ex_reg.NPC;
    assign ex_packet.rd_mem       = id_ex_reg.rd_mem;
    assign ex_packet.wr_mem       = id_ex_reg.wr_mem;
    assign ex_packet.dest_reg_idx = id_ex_reg.dest_reg_idx;
    assign ex_packet.halt         = id_ex_reg.halt;
    assign ex_packet.illegal      = id_ex_reg.illegal;
    assign ex_packet.csr_op       = id_ex_reg.csr_op;
    assign ex_packet.valid        = id_ex_reg.valid;

    // Send rs2_value to the mem stage as the data for a store
    assign ex_packet.rs2_value = id_ex_reg.rs2_value;

    // Break out the signed/unsigned bit and memory read/write size
    assign ex_packet.rd_unsigned = id_ex_reg.inst.r.funct3[2]; // 1 if unsigned, 0 if signed
    assign ex_packet.mem_size    = MEM_SIZE'(id_ex_reg.inst.r.funct3[1:0]);

    // Ultimate "take branch" signal:
    // unconditional, or conditional and the condition is true
    assign ex_packet.take_branch = id_ex_reg.uncond_branch || (id_ex_reg.cond_branch && take_conditional);

    // We split the alu and mult here since they will be split in the final project
    assign ex_packet.alu_result = (id_ex_reg.mult) ? mult_result : alu_result;

    // ALU opA mux
    always_comb begin
        case (id_ex_reg.opa_select)
            OPA_IS_RS1:  opa_mux_out = id_ex_reg.rs1_value;
            OPA_IS_NPC:  opa_mux_out = id_ex_reg.NPC;
            OPA_IS_PC:   opa_mux_out = id_ex_reg.PC;
            OPA_IS_ZERO: opa_mux_out = 0;
            default:     opa_mux_out = 32'hdeadface; // dead face
        endcase
    end

    // ALU opB mux
    always_comb begin
        case (id_ex_reg.opb_select)
            OPB_IS_RS2:   opb_mux_out = id_ex_reg.rs2_value;
            OPB_IS_I_IMM: opb_mux_out = `RV32_signext_Iimm(id_ex_reg.inst);
            OPB_IS_S_IMM: opb_mux_out = `RV32_signext_Simm(id_ex_reg.inst);
            OPB_IS_B_IMM: opb_mux_out = `RV32_signext_Bimm(id_ex_reg.inst);
            OPB_IS_U_IMM: opb_mux_out = `RV32_signext_Uimm(id_ex_reg.inst);
            OPB_IS_J_IMM: opb_mux_out = `RV32_signext_Jimm(id_ex_reg.inst);
            default:      opb_mux_out = 32'hfacefeed; // face feed
        endcase
    end

    // Instantiate the ALU
    alu [NUM_FU_ALU-1:0] alu_0 (
        // Inputs
        .opa(opa_mux_out),
        .opb(opb_mux_out),
        .alu_func(id_ex_reg.alu_func),

        // Output
        .result(alu_result)
    );

    // Instantiate the multiplier
    mult [NUM_FU_MULT-1:0] mults (
        // Inputs
        .clock(clock),
        .reset(reset),
        .start(),
        .rs1(id_ex_reg.rs1_value),
        .rs2(id_ex_reg.rs2_value),
        .func(id_ex_reg.inst.r.funct3), // which mult operation to perform

        // Output
        .result(mult_result),
        .done(mult_done)
    );

    // Instantiate the conditional branch module
    conditional_branch [NUM_FU_BRANCH-1:0] conditional_branchs (
        // Inputs
        .rs1(id_ex_reg.rs1_value),
        .rs2(id_ex_reg.rs2_value),
        .func(id_ex_reg.inst.b.funct3), // Which branch condition to check

        // Output
        .take(take_conditional)
    );

endmodule // stage_ex
