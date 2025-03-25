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

    input   rs2execute ex_fu_in,
    output  execute2rs ex_rdy_out,

    input   prf2execute prf_2_ex,
    output  execute2prf ex_2_prf,

    // TODO: wrap this stuff into execute2complete. Wrap crap here in general.
    output  execute2complete ex_c_out

);
    logic       [`NUM_FU_ALU-1:0]    fu_rdy_alu;
    logic       [`NUM_FU_MULT-1:0]   fu_rdy_mult;
    logic       [`NUM_FU_STORE-1:0]  fu_rdy_store;
    logic       [`NUM_FU_LOAD-1:0]   fu_rdy_load;
    ID_RESULT   [`NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT   [`NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT   [`NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT   [`NUM_FU_LOAD-1:0]   fu_dat_load;

    struct packed {
        DATA        opa_mux_out, opb_mux_out, alu_result;
        ALU_FUNC    alu_func;
        logic       alu_done;
        logic       branch;
        logic       [2:0] branch_func;
        logic       take_conditional;
    } [`NUM_FU_ALU-1:0] alu_bundle;

    struct packed {
        logic       [2:0] mult_func;
        logic       mult_done;
        MULT_DEST   mul_dst_in;
        MULT_DEST   mul_dst_out;
        DATA        mult_value1, mult_value2, mult_result;
    } [`NUM_FU_MULT-1:0] mult_bundle;


    assign ex_rdy_out.fu_rdy_alu = fu_rdy_alu;
    assign ex_rdy_out.fu_rdy_mult = fu_rdy_mult;
    assign ex_rdy_out.fu_rdy_load = fu_rdy_load;
    assign ex_rdy_out.fu_rdy_store = fu_rdy_store;

    always_ff @(posedge clock) begin
        $display("DEBUG: mult_done[0] at cycle %0t = %b", $time,    mult_bundle[0].mult_done);
        $display("DEBUG: mult_result[0] at cycle %0t = %b", $time,  mult_bundle[0].mult_result);
    end
 
    always_comb begin
        ex_c_out = '0;
        for (int i = 0; i < `NUM_FU_MULT; ++i) begin
        $display("MULT_RESULT: %2d",mult_bundle[i].mult_result);
        $display("MULT_DONE: %2d",mult_bundle[i].mult_done);
            ex_c_out.c_en[i]        = !fu_rdy_alu[i];//mult_done[i];
            ex_c_out.c_ts[i]        = fu_dat_alu[i].t;//internal_mul_dat[i].t;
            ex_c_out.c_rob_idxs[i]  = fu_dat_alu[i].rob_idx;//internal_mul_dat[i].rob_idx;
            ex_c_out.c_data[i]      = alu_bundle[i].alu_result;//mult_result[i];
            
            // if (!mult_bundle[i].mult_done)
            //     continue;
            if (mult_bundle[i].mult_done) begin
            ex_c_out.c_en[i]        = mult_bundle[i].mult_done;
            ex_c_out.c_ts[i]        = mult_bundle[i].mul_dst_out.tag;
            ex_c_out.c_rob_idxs[i]  = mult_bundle[i].mul_dst_out.rob_idx;
            ex_c_out.c_data[i]      = mult_bundle[i].mult_result;
            end
        end
    end
   
    generate 
        for(genvar i = 0; i < `NUM_FU_MULT; i++ ) begin
            // Instantiate the ALU
            alu alu_0 ( 
                // Inputs
                .opa        (alu_bundle[i].opa_mux_out),
                .opb        (alu_bundle[i].opb_mux_out),
                .alu_func   (alu_bundle[i].alu_func),
                .branch     (alu_bundle[i].branch), // is this a cond_branch
                .branch_func(alu_bundle[i].branch_func), // Which branch condition to check

                .take       (alu_bundle[i].take_conditional), // True/False condition result (will return FALSE if branch is low)
                .result     (alu_bundle[i].alu_result) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our 
            );
        end
    endgenerate

    generate 
        for(genvar i = 0; i < `NUM_FU_MULT; i++ ) begin
            // Instantiate the multiplier
            mult mult_0 (
                // Inputs
                .clock  (clock),
                .reset  (reset),
                .start  (ex_fu_in.fu_vld_mult[i]),
                .dst_in (mult_bundle[i].mul_dst_in),
                .rs1    (mult_bundle[i].mult_value1),
                .rs2    (mult_bundle[i].mult_value2),
                .func   (mult_bundle[i].mult_func), // which mult operation to perform

                // Output
                .dst_out(mult_bundle[i].mul_dst_out),
                .result (mult_bundle[i].mult_result),
                .done   (mult_bundle[i].mult_done)
        );
        end
    endgenerate


    always_comb begin
        foreach(ex_fu_in.fu_dat_alu[i]) begin
            if(!ex_fu_in.fu_vld_alu[i]) 
                continue;

            ex_2_prf.prf_en[i] = ex_fu_in.fu_vld_alu[i];
            ex_2_prf.s_t1s[i] = ex_fu_in.fu_dat_alu[i].t1;
            ex_2_prf.s_t2s[i] = ex_fu_in.fu_dat_alu[i].t2;


            if (ex_fu_in.fu_dat_alu[i].cond_branch) begin
                alu_bundle[i].opa_mux_out = prf_2_ex.s_v1s[i];
                alu_bundle[i].opb_mux_out = prf_2_ex.s_v2s[i];
                alu_bundle[i].alu_func = 4'ha; //SENTINEL VALUE
                alu_bundle[i].branch_func = ex_fu_in.fu_dat_alu[i].inst.b.funct3;
                alu_bundle[i].branch = 1;
            end else begin
                // ALU opA mux
                case (ex_fu_in.fu_dat_alu[i].opa_select)
                    // OPA_IS_RS1:  opa_mux_out[i] = ex_fu_in.fu_dat_alu[i].rs1_value;
                    OPA_IS_RS1:  alu_bundle[i].opa_mux_out = prf_2_ex.s_v1s[i];
                    OPA_IS_NPC:  alu_bundle[i].opa_mux_out = ex_fu_in.fu_dat_alu[i].NPC;
                    OPA_IS_PC:   alu_bundle[i].opa_mux_out = ex_fu_in.fu_dat_alu[i].PC;
                    OPA_IS_ZERO: alu_bundle[i].opa_mux_out = 0;
                    default:     alu_bundle[i].opa_mux_out= 32'hdeadface; // dead face
                endcase

                // ALU opB mux
                case (ex_fu_in.fu_dat_alu[i].opb_select)
                    // OPB_IS_RS2:   opb_mux_out[i] = ex_fu_in.fu_dat_alu[i].rs2_value;
                    OPB_IS_RS2:   alu_bundle[i].opb_mux_out =  prf_2_ex.s_v2s[i];
                    OPB_IS_I_IMM: alu_bundle[i].opb_mux_out = `RV32_signext_Iimm(ex_fu_in.fu_dat_alu[i].inst);
                    OPB_IS_S_IMM: alu_bundle[i].opb_mux_out = `RV32_signext_Simm(ex_fu_in.fu_dat_alu[i].inst);
                    OPB_IS_B_IMM: alu_bundle[i].opb_mux_out = `RV32_signext_Bimm(ex_fu_in.fu_dat_alu[i].inst);
                    OPB_IS_U_IMM: alu_bundle[i].opb_mux_out = `RV32_signext_Uimm(ex_fu_in.fu_dat_alu[i].inst);
                    OPB_IS_J_IMM: alu_bundle[i].opb_mux_out = `RV32_signext_Jimm(ex_fu_in.fu_dat_alu[i].inst);
                    default:      alu_bundle[i].opb_mux_out = 32'hfacefeed; // face feed
                endcase

                alu_bundle[i].alu_func = ex_fu_in.fu_dat_alu[i].alu_func;
                alu_bundle[i].branch_func = 3'b011; //SENTINEL VALUE
                alu_bundle[i].branch = 0;
            end
        end

        //mult prf interaction
        foreach(ex_fu_in.fu_dat_mult[i]) begin
            if (reset || flush) begin
                mult_bundle[i].mult_value1 = '0;
                mult_bundle[i].mult_value2 = '0;
                mult_bundle[i].mult_func = '0;
            end
            else begin
                if(!ex_fu_in.fu_vld_mult[i]) 
                    continue;

                ex_2_prf.prf_en[i+`NUM_FU_ALU] = ex_fu_in.fu_vld_mult[i];
                
                ex_2_prf.s_t1s[i+`NUM_FU_ALU] = ex_fu_in.fu_dat_mult[i].t1;
                ex_2_prf.s_t2s[i+`NUM_FU_ALU] = ex_fu_in.fu_dat_mult[i].t2;

                mult_bundle[i].mult_value1 = prf_2_ex.s_v1s[i+`NUM_FU_ALU];
                mult_bundle[i].mult_value2 =  prf_2_ex.s_v2s[i+`NUM_FU_ALU];

                mult_bundle[i].mult_func = ex_fu_in.fu_dat_mult[i].inst.r.funct3;
            end

            $display("MULT_VALUE1: %2d",mult_bundle[i].mult_value1);
            $display("MULT_VALUE2: %2d",mult_bundle[i].mult_value2);
        end
    end

    
    always_ff @(posedge clock) begin
        if (reset || flush) begin
            fu_rdy_alu      <= '1;
            fu_rdy_mult     <= '1;
            fu_rdy_store    <= '0;
            fu_rdy_load     <= '0;

            fu_dat_alu      <= '0;
            fu_dat_mult     <= '0;
            fu_dat_store    <= '0;
            fu_dat_load     <= '0;

            foreach(mult_bundle[i]) begin
                mult_bundle[i].mul_dst_in.tag <= '0;
                mult_bundle[i].mul_dst_in.rob_idx <= '0;
            end
            // internal_mul_dat <= '0;
        end else begin
            foreach (fu_rdy_alu[i]) begin
                fu_rdy_alu[i]   <= ex_fu_in.fu_vld_alu[i] ? 0 : (alu_bundle[i].alu_done || fu_rdy_alu[i]);// || ex_c_out.c_en[i]; //OR'ing this will work to reset the flag, just have to make sure it is coming from the right FU so that we don't accidentally reset the ALU with a mult flag or something
                fu_dat_alu[i]   <= ex_fu_in.fu_vld_alu[i] ? ex_fu_in.fu_dat_alu[i] : '0;
                $display("assign: %d vld:%b insn:%x", i, ex_fu_in.fu_vld_alu[i], ex_fu_in.fu_dat_alu[i].inst);
            end

            foreach(fu_rdy_mult[i]) begin
                fu_rdy_mult[i]  <= ex_fu_in.fu_vld_mult[i] ? 0 : (mult_bundle[i].mult_done || fu_rdy_mult[i]);
                fu_dat_mult[i]  <= ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i] : '0;

                mult_bundle[i].mul_dst_in.tag
                    <= ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i].t : mult_bundle[i].mul_dst_in.tag;
                mult_bundle[i].mul_dst_in.rob_idx
                    <= ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i].rob_idx : mult_bundle[i].mul_dst_in.rob_idx; //internal_mul_dat
            end

            for (int i = 0; i < `N; ++i) begin
                $display("ex_c_out[%d]: (en: %b, t: %d, rob_idx: %d, dat: %d)",
                    i,
                    ex_c_out.c_en[i],
                    ex_c_out.c_ts[i],
                    ex_c_out.c_rob_idxs[i],
                    ex_c_out.c_data[i]
                );
            end
        end
    end




endmodule // stage_ex
