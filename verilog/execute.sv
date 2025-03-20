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
    input logic branch, // is this a cond_branch
    input [2:0] branch_func, // Which branch condition to check

    output logic take, // True/False condition result
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

    always_comb begin
        case (branch_func)
            3'b000:  take = signed'(opa) == signed'(opb); // BEQ
            3'b001:  take = signed'(opa) != signed'(opb); // BNE
            3'b100:  take = signed'(opa) <  signed'(opb); // BLT
            3'b101:  take = signed'(opa) >= signed'(opb); // BGE
            3'b110:  take = opa < opb;                    // BLTU
            3'b111:  take = opa >= opb;                   // BGEU
            default: take = `FALSE;
        endcase
    end

endmodule // alu

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
    assign prf_out  = '0;
    assign c_out    = '0;

    // <FU>_ins: staging; where just-issued insns wait for 1 cycle to pull their operands
    struct packed {
        logic   [`NUM_FU_ALU-1:0]   bsy;
        logic   [`NUM_FU_ALU-1:0]   dat;
    } alu_ins;
    struct packed {
        logic   [`NUM_FU_MULT-1:0]   bsy;
        logic   [`NUM_FU_MULT-1:0]   dat;
    } mul_ins;

    // <FU>_outs: where executed insns wait until completion
    struct packed {
        logic   [`NUM_FU_ALU-1:0]   rdy;
        DATA    [`NUM_FU_ALU-1:0]   res;
        DST     [`NUM_FU_ALU-1:0]   dst;
    } alu_outs;
    struct packed {
        logic   [`NUM_FU_MULT-1:0]  rdy;
        DATA    [`NUM_FU_MULT-1:0]  res;
        DST     [`NUM_FU_MULT-1:0]  dst;
    } mul_outs;

    always_comb begin
        rs_out = '{
            fu_rdy_alu      : ~alu_ins.bsy,
            fu_rdy_mult     : ~mul_ins.bsy,
            fu_rdy_load     : '1,
            fu_rdy_store    : '1
        };
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            alu_ins     <= '0;
            mul_ins     <= '0;
        end else begin
            alu_ins.bsy <= alu_ins.bsy ? 
        end
    end



    // logic       [`NUM_FU_ALU-1:0]    fu_rdy_alu;
    // logic       [`NUM_FU_MULT-1:0]   fu_rdy_mult;
    // ID_RESULT   [`NUM_FU_ALU-1:0]    fu_dat_alu;
    // ID_RESULT   [`NUM_FU_MULT-1:0]   fu_dat_mult;
    // DATA [`NUM_FU_ALU-1:0] opa_mux_out, opb_mux_out, alu_result;
    // ALU_FUNC [`NUM_FU_ALU-1:0] alu_func;
    // logic [`NUM_FU_ALU-1:0] alu_done;
    // logic [`NUM_FU_ALU-1:0] branch;
    // logic [`NUM_FU_ALU-1:0] [2:0] branch_func;
    // logic [`NUM_FU_ALU-1:0] take_conditional;

    // logic [`NUM_FU_MULT-1:0] [2:0] mult_func;
    // logic [`NUM_FU_MULT-1:0] mult_done;
    // MULT_DEST [`NUM_FU_MULT-1:0] mul_dst_in;
    // MULT_DEST [`NUM_FU_MULT-1:0] mul_dst_out;
    // DATA  [`NUM_FU_MULT-1:0] mult_value1, mult_value2, mult_result;

    // assign rs_out.fu_rdy_alu = fu_rdy_alu;
    // assign rs_out.fu_rdy_mult = fu_rdy_mult;
    // assign rs_out.fu_rdy_load = fu_rdy_load;
    // assign rs_out.fu_rdy_store = fu_rdy_store;

    // always_ff @(posedge clock) begin
    //     $display("DEBUG: mult_done[0] at cycle %0t = %b", $time, mult_done[0]);
    //     $display("DEBUG: mult_result[0] at cycle %0t = %b", $time, mult_result[0]);
    // end
 
    // always_comb begin
    //     c_out = '0;
    //     for (int i = 0; i < `NUM_FU_MULT; ++i) begin
    //         if (!mult_done[i])
    //             continue;

    //         c_out.c_en[i]        = mult_done[i];
    //         c_out.c_ts[i]        = mul_dst_out[i].tag;
    //         c_out.c_rob_idxs[i]  = mul_dst_out[i].rob_idx;
    //         c_out.c_data[i]      = mult_result[i];
    //     end
    // end

   
    // // // Instantiate the ALU
    // alu alu_0 [`NUM_FU_ALU-1:0] ( 
    //     // Inputs
    //     .opa(opa_mux_out),
    //     .opb(opb_mux_out),
    //     .alu_func(alu_func),
    //     .branch(branch), // is this a cond_branch
    //     .branch_func(branch_func), // Which branch condition to check

    //     .take(take_conditional), // True/False condition result (will return FALSE if branch is low)
    //     .result(alu_result) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
    // );


    // always_comb begin
    //     foreach(rs_in.fu_dat_mult[i]) begin
    //         if(!rs_in.fu_vld_mult[i]) 
    //             continue;

    //         prf_out.prf_en[i] = rs_in.fu_vld_mult[i];
    //         prf_out.s_t1s[i] = rs_in.fu_dat_mult[i].t1;
    //         prf_out.s_t2s[i] = rs_in.fu_dat_mult[i].t2;

    //         case (rs_in.fu_dat_mult[i].opa_select)
    //             // OPA_IS_RS1:  opa_mux_out[i] = rs_in.fu_dat_mult[i].rs1_value;
    //             OPA_IS_RS1:  mult_value1[i] = prf_in.s_v1s[i];
    //             OPA_IS_NPC:  mult_value1[i] = rs_in.fu_dat_mult[i].NPC;
    //             OPA_IS_PC:   mult_value1[i] = rs_in.fu_dat_mult[i].PC;
    //             OPA_IS_ZERO: mult_value1[i] = 0;
    //             default:     mult_value1[i]= 32'hdeadface; // dead face
    //         endcase

    //         // mult opB mux
    //         case (rs_in.fu_dat_mult[i].opb_select)
    //             // OPB_IS_RS2:   opb_mux_out[i] = rs_in.fu_dat_mult[i].rs2_value;
    //             OPB_IS_RS2:   mult_value2[i] =  prf_in.s_v2s[i];
    //             OPB_IS_I_IMM: mult_value2[i] = `RV32_signext_Iimm(rs_in.fu_dat_mult[i].inst);
    //             OPB_IS_S_IMM: mult_value2[i] = `RV32_signext_Simm(rs_in.fu_dat_mult[i].inst);
    //             OPB_IS_B_IMM: mult_value2[i] = `RV32_signext_Bimm(rs_in.fu_dat_mult[i].inst);
    //             OPB_IS_U_IMM: mult_value2[i] = `RV32_signext_Uimm(rs_in.fu_dat_mult[i].inst);
    //             OPB_IS_J_IMM: mult_value2[i] = `RV32_signext_Jimm(rs_in.fu_dat_mult[i].inst);
    //             default:      mult_value2[i] = 32'hfacefeed; // face feed
    //         endcase

    //         mult_func[i] = rs_in.fu_dat_mult[i].alu_func;
    //     end
    // end

    // generate 
    //     for(genvar i = 0; i < `NUM_FU_MULT; i++ ) begin
    //         // Instantiate the multiplier
    //         mult mult_0 (
    //             // Inputs
    //             .clock(clock),
    //             .reset(reset),
    //             .start(rs_in.fu_vld_mult[i]),
    //             .dst_in(mul_dst_in[i]),
    //             .rs1(mult_value1[i]),
    //             .rs2(mult_value2[i]),
    //             .func(rs_in.fu_dat_mult[i].inst.r.funct3), // which mult operation to perform

    //             // Output
    //             .dst_out(mul_dst_out[i]),
    //             .result(mult_result[i]),
    //             .done(mult_done[i])
    //     );
    //     end
    // endgenerate
    
    // always_ff @(posedge clock) begin
    //     if (reset || flush) begin
    //         fu_rdy_alu      <= '1;
    //         fu_rdy_mult     <= '1;

    //         fu_dat_alu      <= '0;
    //         fu_dat_mult     <= '0;
    //         // internal_mul_dat <= '0;
    //     end else begin
    //         foreach (fu_rdy_alu[i]) begin
    //             fu_rdy_alu[i]   <= rs_in.fu_vld_alu[i] ? 0 : (alu_done[i] || fu_rdy_alu[i]);// || c_out.c_en[i]; //OR'ing this will work to reset the flag, just have to make sure it is coming from the right FU so that we don't accidentally reset the ALU with a mult flag or something
    //             fu_dat_alu[i]   <= rs_in.fu_vld_alu[i] ? rs_in.fu_dat_alu[i] : '0;
    //             $display("assign: %d vld:%b insn:%x", i, rs_in.fu_vld_alu[i], rs_in.fu_dat_alu[i].inst);
    //         end

    //         foreach(fu_rdy_mult[i]) begin
    //             fu_rdy_mult[i]  <= rs_in.fu_vld_mult[i] ? 0 : (mult_done[i] || fu_rdy_mult[i]);
    //             fu_dat_mult[i]  <= rs_in.fu_vld_mult[i] ? rs_in.fu_dat_mult[i] : '0;

    //             mul_dst_in[i].tag       <= rs_in.fu_vld_mult[i] ? rs_in.fu_dat_mult[i].t : mul_dst_in[i].tag;
    //             mul_dst_in[i].rob_idx   <= rs_in.fu_vld_mult[i] ? rs_in.fu_dat_mult[i].rob_idx : mul_dst_in[i].rob_idx; //internal_mul_dat
    //         end

    //         for (int i = 0; i < `N; ++i) begin
    //             $display("c_out[%d]: (en: %b, t: %d, rob_idx: %d, dat: %d)",
    //                 i,
    //                 c_out.c_en[i],
    //                 c_out.c_ts[i],
    //                 c_out.c_rob_idxs[i],
    //                 c_out.c_data[i]
    //             );
    //         end
    //     end
    // end




endmodule // stage_ex
