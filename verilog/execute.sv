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
            3'b000:  take = signed'(rs1) == signed'(rs2); // BEQ
            3'b001:  take = signed'(rs1) != signed'(rs2); // BNE
            3'b100:  take = signed'(rs1) <  signed'(rs2); // BLT
            3'b101:  take = signed'(rs1) >= signed'(rs2); // BGE
            3'b110:  take = rs1 < rs2;                    // BLTU
            3'b111:  take = rs1 >= rs2;                   // BGEU
            default: take = `FALSE;
        endcase
    end

endmodule // alu

// // Conditional branch module: compute whether to take conditional branches
// // This module is purely combinational
// module conditional_branch (
//     input DATA  rs1,
//     input DATA  rs2,
    
// );

    

// endmodule // conditional_branch

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
    input clock,
    input reset,

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

    output  logic       [N-1:0]             c_en;
    output  PHYS_REG_IDX[N-1:0]             c_ts;
);

    ALU_FUNC [NUM_FU_ALU-1:0] alu_func;
    DATA [NUM_FU_ALU-1:0] opa_mux_out, opb_mux_out, alu_result;
    logic [NUM_FU_ALU-1:0] branch;
    logic [NUM_FU_MULT-1:0] [2:0] mult_func;
    logic [NUM_FU_MULT-1:0] mult_done;
    DATA [NUM_FU_MULT-1:0] mult_value1, mult_value2, mult_result, 
    logic [NUM_FU_BRANCH-1:0] [2:0] branch_func;
    logic [NUM_FU_BRANCH-1:0] take_conditional;
    // DATA [NUM_FU_BRANCH-1:0] branch_value1, branch_value2;

    /* I don't know what to do with these yet
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
    assign ex_packet.alu_result = (id_ex_reg.mult) ? mult_result : alu_result; */

    always_comb begin
        foreach(fu_dat_alu[i]) begin
            if(fu_vld_alu[i]) begin
                if (fu_dat_alu[i].cond_branch) begin
                    opa_mux_out[i] = fu_dat_alu[i].rs1_value;
                    opb_mux_out[i] = fu_dat_alu[i].rs2_value;
                    alu_func[i] = 4'ha; //SENTINEL VALUE
                    branch_func[i] = fu_dat_alu[i].inst.b.funct3;
                    branch[i] = 1;
                end else begin
                    // ALU opA mux
                    always_comb begin
                        case (fu_dat_alu[i].opa_select)
                            OPA_IS_RS1:  opa_mux_out[i] = fu_dat_alu[i].rs1_value;
                            OPA_IS_NPC:  opa_mux_out[i] = fu_dat_alu[i].NPC;
                            OPA_IS_PC:   opa_mux_out[i] = fu_dat_alu[i].PC;
                            OPA_IS_ZERO: opa_mux_out[i] = 0;
                            default:     opa_mux_out[i]= 32'hdeadface; // dead face
                        endcase
                    end

                    // ALU opB mux
                    always_comb begin
                        case (fu_dat_alu[i].opb_select)
                            OPB_IS_RS2:   opb_mux_out[i] = fu_dat_alu[i].rs2_value;
                            OPB_IS_I_IMM: opb_mux_out[i] = `RV32_signext_Iimm(fu_dat_alu[i].inst);
                            OPB_IS_S_IMM: opb_mux_out[i] = `RV32_signext_Simm(fu_dat_alu[i].inst);
                            OPB_IS_B_IMM: opb_mux_out[i] = `RV32_signext_Bimm(fu_dat_alu[i].inst);
                            OPB_IS_U_IMM: opb_mux_out[i] = `RV32_signext_Uimm(fu_dat_alu[i].inst);
                            OPB_IS_J_IMM: opb_mux_out[i] = `RV32_signext_Jimm(fu_dat_alu[i].inst);
                            default:      opb_mux_out[i] = 32'hfacefeed; // face feed
                        endcase
                    end

                    alu_func[i] = fu_dat_alu[i].alu_func;
                    branch_func[i] = 3'b011; //SENTINEL VALUE
                    branch[i] = 0;
                end
            end
        end

        foreach(fu_dat_mult[i]) begin
            mult_func[i] = fu_vld_mult[i] ? fu_dat_mult[i].inst.r.funct3 : '0;
            mult_value1[i] = fu_vld_mult[i] ? fu_dat_mult[i].rs1_value : '0;
            mult_value2[i] = fu_vld_mult[i] ? fu_dat_mult[i].rs2_value : '0;
        end
    end

   
    // Instantiate the ALU
    alu alu_0 [NUM_FU_ALU-1:0] (
        // Inputs
        .opa(opa_mux_out),
        .opb(opb_mux_out),
        .alu_func(id_ex_reg.alu_func),
        .branch(branch), // is this a cond_branch
        .branch_func(branch_func), // Which branch condition to check

        .take(take_conditional), // True/False condition result (will return FALSE if branch is low)
        .result(alu_result) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
    );
    // Instantiate the multiplier
    mult mults [NUM_FU_MULT-1:0] (
        // Inputs
        .clock(clock),
        .reset(reset),
        .start(fu_vld_mult),
        .rs1(id_ex_reg.rs1_value),
        .rs2(id_ex_reg.rs2_value),
        .func(id_ex_reg.inst.r.funct3), // which mult operation to perform

        // Output
        .result(mult_result),
        .done(mult_done)
    );

    // // Instantiate the conditional branch module
    // conditional_branch conditional_branchs [NUM_FU_BRANCH-1:0] (
    //     // Inputs
    //     .rs1(id_ex_reg.rs1_value),
    //     .rs2(id_ex_reg.rs2_value),
    //     .func(id_ex_reg.inst.b.funct3), // Which branch condition to check

    //     // Output
    //     .take(take_conditional)
    // );

    always_ff @(posedge clock) begin
        foreach(fu_dat_alu[i]) begin
            if (reset) begin
                fu_rdy_alu[i] <= 0;
            end else if ((!branch[i] && alu_result[i] != 32'hfacebeec) || branch[i]) begin
                fu_rdy_alu[i] <= 0;
            end else begin
                fu_rdy_alu[i] <= 1;
            end
        end

        foreach(fu_dat_mult[i]) begin
            if (reset) begin
                fu_rdy_mult[i] <= 0;
            end else if (mult_done[i]) begin
                fu_rdy_mult[i] <= 1;
            end else if (fu_vld_mult[i]) begin
                fu_rdy_mult[i] <= 0;
            end else begin
                fu_rdy_mult[i] <= fu_rdy_mult[i];
            end
        end
    end

    always_comb begin
       
        PHYS_REG_IDX completed_tags [NUM_FU_ALU + NUM_FU_MULT + NUM_FU_LOAD + NUM_FU_STORE];
        int completed_ids [NUM_FU_ALU + NUM_FU_MULT + NUM_FU_LOAD + NUM_FU_STORE];
        logic [$clog2(NUM_FU_ALU + NUM_FU_MULT + NUM_FU_LOAD + NUM_FU_STORE)-1:0] completed_count = '0;

        
        for (int i = 0; i < NUM_FU_ALU; i++) begin
            if (fu_vld_alu[i] && fu_dat_alu[i].alu_func != default) begin
                completed_tags[completed_count] = fu_dat_alu[i].t;
                completed_ids[completed_count] = fu_dat_alu[i].id;
                completed_count++;
            end
        end

        for (int i = 0; i < NUM_FU_MULT; i++) begin
            if (fu_vld_mult[i] && fu_dat_mult[i].mult_done) begin
                completed_tags[completed_count] = fu_dat_mult[i].t;
                completed_ids[completed_count] = fu_dat_mult[i].id;
                completed_count++;
            end
        end

        for (int i = 0; i < NUM_FU_LOAD; i++) begin
            if (fu_vld_load[i]) begin
                completed_tags[completed_count] = fu_dat_load[i].t;
                completed_ids[completed_count] = fu_dat_load[i].id;
                completed_count++;
            end
        end

        for (int i = 0; i < NUM_FU_STORE; i++) begin
            if (fu_vld_store[i]) begin
                completed_tags[completed_count] = fu_dat_store[i].t;
                completed_ids[completed_count] = fu_dat_store[i].id;
                completed_count++;
            end
        end

        // Step 3: Find the two oldest completions without sorting everything
        int oldest_id = 999999;       // Large initial value for min search
        PHYS_REG_IDX oldest_tag = '0; // Default to zero to avoid uninitialized values
        int second_oldest_id = 999999;
        PHYS_REG_IDX second_oldest_tag = '0; // Default to zero

        for (int i = 0; i < completed_count; i++) begin
            if (completed_ids[i] < oldest_id) begin
                second_oldest_id = oldest_id;
                second_oldest_tag = oldest_tag;
                oldest_id = completed_ids[i];
                oldest_tag = completed_tags[i];
            end else if (completed_ids[i] < second_oldest_id) begin
                second_oldest_id = completed_ids[i];
                second_oldest_tag = completed_tags[i];
            end
        end

        // Step 4: Assign the selected oldest completions
        c_en = '0; // Initialize completion enable signals
        c_ts = '0; // Initialize completed physical register tags

        case (completed_count)
            0: begin
                // Default case: No completions this cycle
                c_en = '0;
                c_ts = '0;
            end
            1: begin
                // Only one instruction finished
                c_en[0] = 1'b1;
                c_ts[0] = oldest_tag;
            end
            default: begin
                // Two or more completions: Take the two oldest
                c_en[0] = 1'b1;
                c_ts[0] = oldest_tag;
                c_en[1] = 1'b1;
                c_ts[1] = second_oldest_tag;
            end
        endcase
    end



    always_comb begin
       
        PHYS_REG_IDX completed_tags [NUM_FU_ALU + NUM_FU_MULT + NUM_FU_LOAD + NUM_FU_STORE];
        int completed_ids [NUM_FU_ALU + NUM_FU_MULT + NUM_FU_LOAD + NUM_FU_STORE];
        int completed_count = 0;

        
        for (int i = 0; i < NUM_FU_ALU; i++) begin
            if (fu_vld_alu[i] && fu_dat_alu[i].alu_func != default) begin
                completed_tags[completed_count] = fu_dat_alu[i].t;
                completed_ids[completed_count] = fu_dat_alu[i].id;
                completed_count++;
            end
        end

        for (int i = 0; i < NUM_FU_MULT; i++) begin
            if (fu_vld_mult[i] && fu_dat_mult[i].mult_done) begin
                completed_tags[completed_count] = fu_dat_mult[i].t;
                completed_ids[completed_count] = fu_dat_mult[i].id;
                completed_count++;
            end
        end

        for (int i = 0; i < NUM_FU_LOAD; i++) begin
            if (fu_vld_load[i]) begin
                completed_tags[completed_count] = fu_dat_load[i].t;
                completed_ids[completed_count] = fu_dat_load[i].id;
                completed_count++;
            end
        end

        for (int i = 0; i < NUM_FU_STORE; i++) begin
            if (fu_vld_store[i]) begin
                completed_tags[completed_count] = fu_dat_store[i].t;
                completed_ids[completed_count] = fu_dat_store[i].id;
                completed_count++;
            end
        end

        // Step 3: Find the two oldest completions without sorting everything
        int oldest_id = 999999;       // Large initial value for min search
        PHYS_REG_IDX oldest_tag = '0; // Default to zero to avoid uninitialized values
        int second_oldest_id = 999999;
        PHYS_REG_IDX second_oldest_tag = '0; // Default to zero

        for (int i = 0; i < completed_count; i++) begin
            if (completed_ids[i] < oldest_id) begin
                second_oldest_id = oldest_id;
                second_oldest_tag = oldest_tag;
                oldest_id = completed_ids[i];
                oldest_tag = completed_tags[i];
            end else if (completed_ids[i] < second_oldest_id) begin
                second_oldest_id = completed_ids[i];
                second_oldest_tag = completed_tags[i];
            end
        end

        // Step 4: Assign the selected oldest completions
        c_en = '0; // Initialize completion enable signals
        c_ts = '0; // Initialize completed physical register tags

        case (completed_count)
            0: begin
                // Default case: No completions this cycle
                c_en = '0;
                c_ts = '0;
            end
            1: begin
                // Only one instruction finished
                c_en[0] = 1'b1;
                c_ts[0] = oldest_tag;
            end
            default: begin
                // Two or more completions: Take the two oldest
                c_en[0] = 1'b1;
                c_ts[0] = oldest_tag;
                c_en[1] = 1'b1;
                c_ts[1] = second_oldest_tag;
            end
        endcase
    end





endmodule // stage_ex
