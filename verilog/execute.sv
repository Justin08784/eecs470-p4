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
 
 // // Conditional branch module: compute whether to take conditional branches
 // // This module is purely combinational
 // module conditional_branch (
 //     input DATA  rs1,
 //     input DATA  rs2,
 
 // );
 
 
 
 // endmodule // conditional_branch
 
 /*module mult_no_pipeline (
      input clock, reset, start,
      input DATA rs1, rs2,
      input MULT_FUNC func,
 
      output DATA  result,
      output logic done
  );
 
      logic [63:0] mcand, mplier, product;
 
      assign product = mcand * mplier;
 
      // Sign-extend the multiplier inputs based on the operation
      always_comb begin
          case (func)
              M_MUL, M_MULH, M_MULHSU: mcand = {{(32){rs1[31]}}, rs1};
              default:                 mcand = {32'b0, rs1};
          endcase
          case (func)
              M_MUL, M_MULH: mplier = {{(32){rs2[31]}}, rs2};
              default:       mplier = {32'b0, rs2};
          endcase
      end
 
      // Use the high or low bits of the product based on the output func
      assign result = (func == M_MUL) ? product[31:0] : product[63:32];
 
  endmodule*/
 
 
 
 module stage_ex_p4 (
     input clock,
     input reset,
     input flush,
 
     input   rs2execute ex_fu_in,
     // input   logic       [`NUM_FU_ALU-1:0]    fu_vld_alu,
     // input   logic       [`NUM_FU_MULT-1:0]   fu_vld_mult,
     // input   logic       [`NUM_FU_STORE-1:0]  fu_vld_store,
     // input   logic       [`NUM_FU_LOAD-1:0]   fu_vld_load,
     // input   ID_RESULT   [`NUM_FU_ALU-1:0]    fu_dat_alu,
     // input   ID_RESULT   [`NUM_FU_MULT-1:0]   fu_dat_mult,
     // input   ID_RESULT   [`NUM_FU_STORE-1:0]  fu_dat_store,
     // input   ID_RESULT   [`NUM_FU_LOAD-1:0]   fu_dat_load,
 
     input   prf2execute prf_2_ex,
 
     output  execute2rs ex_rdy_out,
     // output  logic       [`NUM_FU_ALU-1:0]    fu_rdy_alu,
     // output  logic       [`NUM_FU_MULT-1:0]   fu_rdy_mult,
     // output  logic       [`NUM_FU_STORE-1:0]  fu_rdy_store,
     // output  logic       [`NUM_FU_LOAD-1:0]   fu_rdy_load,
 
     // TODO: wrap this stuff into execute2complete. Wrap crap here in general.
     output  execute2complete ex_c_out,
     // output  logic       [`N-1:0]             c_en,
     // output  PHYS_REG_IDX[`N-1:0]             c_ts,
     // output  DATA        [`N-1:0]             c_data
 
     output  execute2prf ex_2_prf
 );
     logic   [`NUM_FU_ALU-1:0]    fu_rdy_alu;
     logic   [`NUM_FU_MULT-1:0]   fu_rdy_mult;
     logic   [`NUM_FU_STORE-1:0]  fu_rdy_store;
     logic   [`NUM_FU_LOAD-1:0]   fu_rdy_load;
     ID_RESULT   [`NUM_FU_ALU-1:0]    fu_dat_alu;
     ID_RESULT   [`NUM_FU_MULT-1:0]   fu_dat_mult;
     ID_RESULT   [`NUM_FU_STORE-1:0]  fu_dat_store;
     ID_RESULT   [`NUM_FU_LOAD-1:0]   fu_dat_load;
     DATA [`NUM_FU_ALU-1:0] opa_mux_out, opb_mux_out, alu_result;
     ALU_FUNC [`NUM_FU_ALU-1:0] alu_func;
     logic [`NUM_FU_ALU-1:0] alu_done;
     logic [`NUM_FU_ALU-1:0] branch;
     logic [`NUM_FU_MULT-1:0] [2:0] mult_func;
     logic [`NUM_FU_MULT-1:0] mult_done;
     DATA [`NUM_FU_MULT-1:0] mult_value1, mult_value2, mult_result;
     logic [`NUM_FU_ALU-1:0] [2:0] branch_func;
     logic [`NUM_FU_ALU-1:0] take_conditional;
     internalEXbuffer [`NUM_FU_MULT-1:0] internal_mul_dat;
 
     assign ex_rdy_out.fu_rdy_alu = fu_rdy_alu;
     assign ex_rdy_out.fu_rdy_mult = fu_rdy_mult;
     assign ex_rdy_out.fu_rdy_load = fu_rdy_load;
     assign ex_rdy_out.fu_rdy_store = fu_rdy_store;
 
     always_ff @( posedge clock ) begin
         
        $display("DEBUG: mult_done[0] at cycle %0t = %b", $time, mult_done[0]);
        $display("DEBUG: mult_result[0] at cycle %0t = %b", $time, mult_result[0]);
     end
 
    always_comb begin
        ex_c_out = '0;
        for (int i = 0; i < `NUM_FU_MULT; ++i) begin
            ex_c_out.c_en[i]        = mult_done[i];
            ex_c_out.c_ts[i]        = internal_mul_dat[i].t;
            ex_c_out.c_rob_idxs[i]  = internal_mul_dat[i].rob_idx;
            ex_c_out.c_data[i]      = mult_result[i];
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
            internal_mul_dat <= '0;
        end else begin
            foreach (fu_rdy_alu[i]) begin
                fu_rdy_alu[i]   <= ex_fu_in.fu_vld_alu[i] ? 0 : (alu_done[i] || fu_rdy_alu[i]);// || ex_c_out.c_en[i]; //OR'ing this will work to reset the flag, just have to make sure it is coming from the right FU so that we don't accidentally reset the ALU with a mult flag or something
                fu_dat_alu[i]   <= ex_fu_in.fu_vld_alu[i] ? ex_fu_in.fu_dat_alu[i] : '0;
                $display("assign: %d vld:%b insn:%x", i, ex_fu_in.fu_vld_alu[i], ex_fu_in.fu_dat_alu[i].inst);
            end

            foreach(fu_rdy_mult[i]) begin
                fu_rdy_mult[i] <= ex_fu_in.fu_vld_mult[i] ? 0 : (mult_done[i] || fu_rdy_mult[i]);
                fu_dat_mult[i]   <= ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i] : '0;
                internal_mul_dat[i].t   <= ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i].t : internal_mul_dat[i].t;
                internal_mul_dat[i].rob_idx   <= ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i].rob_idx : internal_mul_dat[i].rob_idx; //internal_mul_dat
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

    // ALU_FUNC [`NUM_FU_ALU-1:0] alu_func;
 //   DATA [`NUM_FU_ALU-1:0] opa_mux_out, opb_mux_out, alu_result;
    // logic [`NUM_FU_ALU-1:0] branch;
    // logic [`NUM_FU_MULT-1:0] [2:0] mult_func;
    // logic [`NUM_FU_MULT-1:0] mult_done;
    // DATA [`NUM_FU_MULT-1:0] mult_value1, mult_value2, mult_result;
    // logic [`NUM_FU_ALU-1:0] [2:0] branch_func;
    // logic [`NUM_FU_ALU-1:0] take_conditional;
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

    // always_comb begin
    //     foreach(ex_fu_in.fu_dat_alu[i]) begin
    //         if(!ex_fu_in.fu_vld_alu[i]) 
    //             continue;

    //         ex_2_prf.prf_en[i] = ex_fu_in.fu_vld_alu[i];
    //         ex_2_prf.s_t1s[i] = ex_fu_in.fu_dat_alu[i].t1;
    //         ex_2_prf.s_t2s[i] = ex_fu_in.fu_dat_alu[i].t2;


    //         if (ex_fu_in.fu_dat_alu[i].cond_branch) begin
    //             opa_mux_out[i] = prf_2_ex.s_v1s[i];
    //             opb_mux_out[i] = prf_2_ex.s_v2s[i];
    //             alu_func[i] = 4'ha; //SENTINEL VALUE
    //             branch_func[i] = ex_fu_in.fu_dat_alu[i].inst.b.funct3;
    //             branch[i] = 1;
    //         end else begin
    //             // ALU opA mux
    //             case (ex_fu_in.fu_dat_alu[i].opa_select)
    //                 // OPA_IS_RS1:  opa_mux_out[i] = ex_fu_in.fu_dat_alu[i].rs1_value;
    //                 OPA_IS_RS1:  opa_mux_out[i] = prf_2_ex.s_v1s[i];
    //                 OPA_IS_NPC:  opa_mux_out[i] = ex_fu_in.fu_dat_alu[i].NPC;
    //                 OPA_IS_PC:   opa_mux_out[i] = ex_fu_in.fu_dat_alu[i].PC;
    //                 OPA_IS_ZERO: opa_mux_out[i] = 0;
    //                 default:     opa_mux_out[i]= 32'hdeadface; // dead face
    //             endcase

    //             // ALU opB mux
    //             case (ex_fu_in.fu_dat_alu[i].opb_select)
    //                 // OPB_IS_RS2:   opb_mux_out[i] = ex_fu_in.fu_dat_alu[i].rs2_value;
    //                 OPB_IS_RS2:   opb_mux_out[i] =  prf_2_ex.s_v2s[i];
    //                 OPB_IS_I_IMM: opb_mux_out[i] = `RV32_signext_Iimm(ex_fu_in.fu_dat_alu[i].inst);
    //                 OPB_IS_S_IMM: opb_mux_out[i] = `RV32_signext_Simm(ex_fu_in.fu_dat_alu[i].inst);
    //                 OPB_IS_B_IMM: opb_mux_out[i] = `RV32_signext_Bimm(ex_fu_in.fu_dat_alu[i].inst);
    //                 OPB_IS_U_IMM: opb_mux_out[i] = `RV32_signext_Uimm(ex_fu_in.fu_dat_alu[i].inst);
    //                 OPB_IS_J_IMM: opb_mux_out[i] = `RV32_signext_Jimm(ex_fu_in.fu_dat_alu[i].inst);
    //                 default:      opb_mux_out[i] = 32'hfacefeed; // face feed
    //             endcase

    //             alu_func[i] = ex_fu_in.fu_dat_alu[i].alu_func;
    //             branch_func[i] = 3'b011; //SENTINEL VALUE
    //             branch[i] = 0;
    //         end
    //     end

    // //     foreach(ex_fu_in.fu_dat_mult[i]) begin
    // //         mult_func[i] = ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i].inst.r.funct3 : '0;
    // //         mult_value1[i] = ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i].rs1_value : '0;
    // //         mult_value2[i] = ex_fu_in.fu_vld_mult[i] ? ex_fu_in.fu_dat_mult[i].rs2_value : '0;
    // //     end
    // end

   
    // // Instantiate the ALU
    alu alu_0 [`NUM_FU_ALU-1:0] ( 
        // Inputs
        .opa(opa_mux_out),
        .opb(opb_mux_out),
        .alu_func(alu_func),
        .branch(branch), // is this a cond_branch
        .branch_func(branch_func), // Which branch condition to check

        .take(take_conditional), // True/False condition result (will return FALSE if branch is low)
        .result(alu_result) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
    );


    always_comb begin
        foreach(ex_fu_in.fu_dat_mult[i]) begin
            if(!ex_fu_in.fu_vld_mult[i]) 
                continue;

            ex_2_prf.prf_en[i] = ex_fu_in.fu_vld_mult[i];
            ex_2_prf.s_t1s[i] = ex_fu_in.fu_dat_mult[i].t1;
            ex_2_prf.s_t2s[i] = ex_fu_in.fu_dat_mult[i].t2;


            // if (ex_fu_in.fu_dat_mult[i].cond_branch) begin
            //     opa_mux_out[i] = prf_2_ex.s_v1s[i];
            //     opb_mux_out[i] = prf_2_ex.s_v2s[i];
            //     mult_func[i] = 4'ha; //SENTINEL VALUE
            //     // branch_func[i] = ex_fu_in.fu_dat_mult[i].inst.b.funct3;
            //     // branch[i] = 1;
            // end else begin
                // mult opA mux
                case (ex_fu_in.fu_dat_mult[i].opa_select)
                    // OPA_IS_RS1:  opa_mux_out[i] = ex_fu_in.fu_dat_mult[i].rs1_value;
                    OPA_IS_RS1:  mult_value1[i] = prf_2_ex.s_v1s[i];
                    OPA_IS_NPC:  mult_value1[i] = ex_fu_in.fu_dat_mult[i].NPC;
                    OPA_IS_PC:   mult_value1[i] = ex_fu_in.fu_dat_mult[i].PC;
                    OPA_IS_ZERO: mult_value1[i] = 0;
                    default:     mult_value1[i]= 32'hdeadface; // dead face
                endcase

                // mult opB mux
                case (ex_fu_in.fu_dat_mult[i].opb_select)
                    // OPB_IS_RS2:   opb_mux_out[i] = ex_fu_in.fu_dat_mult[i].rs2_value;
                    OPB_IS_RS2:   mult_value2[i] =  prf_2_ex.s_v2s[i];
                    OPB_IS_I_IMM: mult_value2[i] = `RV32_signext_Iimm(ex_fu_in.fu_dat_mult[i].inst);
                    OPB_IS_S_IMM: mult_value2[i] = `RV32_signext_Simm(ex_fu_in.fu_dat_mult[i].inst);
                    OPB_IS_B_IMM: mult_value2[i] = `RV32_signext_Bimm(ex_fu_in.fu_dat_mult[i].inst);
                    OPB_IS_U_IMM: mult_value2[i] = `RV32_signext_Uimm(ex_fu_in.fu_dat_mult[i].inst);
                    OPB_IS_J_IMM: mult_value2[i] = `RV32_signext_Jimm(ex_fu_in.fu_dat_mult[i].inst);
                    default:      mult_value2[i] = 32'hfacefeed; // face feed
                endcase

                mult_func[i] = ex_fu_in.fu_dat_mult[i].inst.r.funct3;
                // branch_func[i] = 3'b011; //SENTINEL VALUE
                // branch[i] = 0;
            // end
        end
    end

    generate 
        for(genvar i = 0; i < `NUM_FU_MULT; i++ ) begin
        // Instantiate the multiplier
            mult mult_0 (
                // Inputs
                .clock(clock),
                .reset(reset),
                .start(ex_fu_in.fu_vld_mult[i]),
                .rs1(mult_value1[i]),
                .rs2(mult_value2[i]),
                .func(ex_fu_in.fu_dat_mult[i].inst.r.funct3), // which mult operation to perform

    //     // Output
                .result(mult_result[i]),
                .done(mult_done[i])
        );
        end
    endgenerate

    // // // Instantiate the conditional branch module
    // // conditional_branch conditional_branchs [NUM_FU_BRANCH-1:0] (
    // //     // Inputs
    // //     .rs1(id_ex_reg.rs1_value),
    // //     .rs2(id_ex_reg.rs2_value),
    // //     .func(id_ex_reg.inst.b.funct3), // Which branch condition to check

    // //     // Output
    // //     .take(take_conditional)
    // // );

    // always_ff @(posedge clock) begin
    //     foreach(ex_fu_in.fu_dat_alu[i]) begin
    //         if (reset) begin
    //             ex_rdy_out.fu_rdy_alu[i] <= 0;
    //         /*end else if ((!branch[i] && alu_result[i] != 32'hfacebeec) || branch[i]) begin
    //             ex_rdy_out.fu_rdy_alu[i] <= 0;*/
    //         end else begin
    //             ex_rdy_out.fu_rdy_alu[i] <= 1;
    //         end
    //     end

    //     foreach(ex_fu_in.fu_dat_mult[i]) begin
    //         if (reset) begin
    //             ex_rdy_out.fu_rdy_mult[i] <= 0;
    //         end else if (mult_done[i]) begin
    //             ex_rdy_out.fu_rdy_mult[i] <= 1;
    //         end else if (ex_fu_in.fu_vld_mult[i]) begin
    //             ex_rdy_out.fu_rdy_mult[i] <= 0;
    //         end else begin
    //             ex_rdy_out.fu_rdy_mult[i] <= ex_rdy_out.fu_rdy_mult[i];
    //         end
    //     end

    //     ex_rdy_out.fu_rdy_store <= '0; //TODO: modify once memory functionality is implemented
    //     ex_rdy_out.fu_rdy_load  <= '0;
    // end

    
    // execute2complete next_ex2complete;

    // logic [`NUM_FU_ALU-1:0] alu_done;
    // logic [`NUM_FU_ALU-1:0] grant;
    // //logic [`NUM_FU_MULT-1:0] select;

    // logic [`N-1:0][`NUM_FU_ALU-1:0] grant_bus;
    // logic empty;

    // //assign alu_done = 4'b0000;
    // //assign grant = 4'b0000;

    // psel_gen #(
    // .WIDTH  (`NUM_FU_ALU),
    // .REQS   (`N)
    // ) sel_alu (
    // .req    (alu_done),
    // .gnt    (grant),
    // .gnt_bus(grant_bus),
    // .empty  (empty)
    // );

    

    


    // always_comb begin     

    //     next_ex2complete.c_en = '0; // Initialize completion enable signals
    //     next_ex2complete.c_ts = '0; // Initialize completed physical register tags
    //     next_ex2complete.c_data = '0;
    //     next_ex2complete.c_rob_idxs = '0;

    //     alu_done = '0;//2'b00;
    //     foreach(alu_result[i]) begin
    //         // $display("DEBUG: alu_result[i] at cycle %0t = %0d", $time, alu_result[i]);
    //         alu_done[i] |= (alu_result[i] != 32'hfacebeec);
    //         // $display("DEBUG: alu_done at cycle %0t = %2b", $time, alu_done);
    //         // $display("DEBUG: gnt at cycle %0t = %2b", $time, grant);
    //         // $display("DEBUG: gnt_bus at cycle %0t = %2b", $time, grant_bus);
    //     end

      
    //     // next_ex2complete.c_en[0] =  grant_bus[0];
    //     // next_ex2complete.c_en[1] =  grant_bus[1];

    //     next_ex2complete.c_data[0] = alu_result[0];
    //     // next_ex2complete.c_data[1] = alu_result[1];

    //     /*if (next_ex2complete.c_en[0]) begin
    //         next_ex2complete.c_data[0] = grant_bus[0] ? alu_result[0] : '0; 
    //     end 

    //     if(next_ex2complete.c_en[1]) begin
    //         next_ex2complete.c_data[1] =  grant_bus[1] ?  alu_result[grant_bus[1]]; 
    //     end*/

    // end

    // always_ff @(posedge clock) begin
    //     if(reset) begin
    //         ex_c_out.c_en <= '0; // Initialize completion enable signals
    //         ex_c_out.c_ts <= '0; // Initialize completed physical register tags
    //         ex_c_out.c_data <= '0;
    //         ex_c_out.c_rob_idxs <= '0;


    //         /*ex_rdy_out.fu_rdy_alu <= '0;
    //         ex_rdy_out.fu_rdy_mult <= '0;
    //         ex_rdy_out.fu_rdy_load <= '0;
    //         ex_rdy_out.fu_rdy_store <= '0;*/
    //     end else begin
    //         ex_c_out.c_en <= next_ex2complete.c_en; // Initialize completion enable signals
    //         ex_c_out.c_ts <= next_ex2complete.c_ts; // Initialize completed physical register tags
    //         ex_c_out.c_data <= next_ex2complete.c_data;
    //         ex_c_out.c_rob_idxs <= next_ex2complete.c_rob_idxs;
    //     end
    // end





endmodule // stage_ex
