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
    input DATA      opa,
    input DATA      opb,
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

    // <FU>_ins: staging; where just-issued insns wait for 1 cycle to pull their operands
    struct packed {
        logic       [`NUM_FU_ALU-1:0]   bsy;
        ID_RESULT   [`NUM_FU_ALU-1:0]   dat;
    } alu_ins;
    struct packed {
        DATA [`NUM_FU_ALU-1:0] opa, opb;
    } alu_operands;
    struct packed {
        logic       [`NUM_FU_MULT-1:0]  bsy;
        ID_RESULT   [`NUM_FU_MULT-1:0]  dat;
    } mul_ins;

    // <FU>_outs: where executed insns wait until completion
    struct packed {
        // ff
        logic   [`NUM_FU_ALU-1:0]   rdy;
        DATA    [`NUM_FU_ALU-1:0]   res;
        DST     [`NUM_FU_ALU-1:0]   dst;
    } alu_outs;
    DATA [`NUM_FU_ALU-1:0] alu_res_n;

    struct packed {
        // ff
        logic   [`NUM_FU_MULT-1:0]  rdy;
        DATA    [`NUM_FU_MULT-1:0]  res;
        DST     [`NUM_FU_MULT-1:0]  dst;
    } mul_outs;
    DATA [`NUM_FU_MULT-1:0] mul_res_n;
    DST     [`NUM_FU_MULT-1:0] mul_dst_n;
    logic   [`NUM_FU_MULT-1:0] mul_vld_n;

    // extract ALU operands
    always_comb begin
        foreach(alu_ins.dat[i]) begin
            if(!alu_ins.bsy[i]) 
                continue;

            // ALU opA mux
            case (alu_ins.dat[i].opa_select)
                OPA_IS_RS1:  alu_operands.opa[i] = prf_in.s_v1s[i];
                OPA_IS_NPC:  alu_operands.opa[i] = alu_ins.dat[i].NPC;
                OPA_IS_PC:   alu_operands.opa[i] = alu_ins.dat[i].PC;
                OPA_IS_ZERO: alu_operands.opa[i] = 0;
                default:     alu_operands.opa[i]= 32'hdeadface; // dead face
            endcase

            // ALU opB mux
            case (alu_ins.dat[i].opb_select)
                OPB_IS_RS2:   alu_operands.opb[i] =  prf_in.s_v2s[i];
                OPB_IS_I_IMM: alu_operands.opb[i] = `RV32_signext_Iimm(alu_ins.dat[i].inst);
                OPB_IS_S_IMM: alu_operands.opb[i] = `RV32_signext_Simm(alu_ins.dat[i].inst);
                OPB_IS_B_IMM: alu_operands.opb[i] = `RV32_signext_Bimm(alu_ins.dat[i].inst);
                OPB_IS_U_IMM: alu_operands.opb[i] = `RV32_signext_Uimm(alu_ins.dat[i].inst);
                OPB_IS_J_IMM: alu_operands.opb[i] = `RV32_signext_Jimm(alu_ins.dat[i].inst);
                default:      alu_operands.opb[i] = 32'hfacefeed; // face feed
            endcase

        end
    end


    generate
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            // // Instantiate the ALU
            // TODO: These ALU inputs were kinda hardcoded. Need mux stuff to select which type.
            alu alu_0 ( 
                // Inputs
                .opa(alu_operands.opa[i]),
                .opb(alu_operands.opb[i]),
                .alu_func   (alu_ins.dat[i].alu_func),
                .branch_func(alu_ins.dat[i].inst.r.funct3), // Which branch condition to check

                .take(), // True/False condition result (will return FALSE if branch is low)
                .result(alu_res_n[i]) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
            );
        end
    endgenerate

    generate
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mults
            // // Instantiate the ALU
            // TODO: These ALU inputs were kinda hardcoded. Need mux stuff to select which type.
            mult mult_0 ( 
                .clock(clock),
                .reset(reset),
                .start(mul_ins.bsy[i]),
                .dst_in('{
                    rob_idx : mul_ins.dat[i].rob_idx,
                    tag     : mul_ins.dat[i].t
                }),
                .rs1(prf_in.s_v1s[i + `NUM_FU_ALU]),
                .rs2(prf_in.s_v2s[i + `NUM_FU_ALU]),
                .func(mul_ins.dat[i].inst.r.funct3), // which mult operation to perform

                // Output
                .dst_out(mul_dst_n[i]),
                .result (mul_res_n[i]),
                .done   (mul_vld_n[i])
            );
        end
    endgenerate

    localparam NUM_FU_TOTAL = `NUM_FU_ALU + `NUM_FU_MULT;
    logic [NUM_FU_TOTAL-1:0] all_rdy;
    logic [NUM_FU_TOTAL-1:0] cpl_gnt;
    logic [`N-1:0][NUM_FU_TOTAL-1:0] cdb2fu_gbus;
    assign all_rdy = {
        mul_outs.rdy,
        alu_outs.rdy
    };

    psel_gen #(
        .WIDTH(NUM_FU_TOTAL),
        .REQS(`N)
    ) sel_cpl (
        .req(all_rdy),
        .gnt(cpl_gnt),
        .gnt_bus(cdb2fu_gbus)
    );

    int unsigned off;
    always_comb begin
        rs_out = '{
            fu_rdy_alu      : ~alu_ins.bsy,
            fu_rdy_mult     : ~mul_ins.bsy,
            fu_rdy_load     : '0,
            fu_rdy_store    : '0
        };

        c_out = '0;
        foreach (cdb2fu_gbus[c, f]) begin
            if (!cdb2fu_gbus[c][f])
                continue;

            if (f < `NUM_FU_ALU) begin
                off = f;
                c_out.c_en[off]         |= 1;
                c_out.c_ts[off]         |= alu_outs.dst[off].tag;
                c_out.c_rob_idxs[off]   |= alu_outs.dst[off].rob_idx;
                c_out.c_data[off]       |= alu_outs.res[off];
            end else begin
                if (!(reset || flush))
                    $error("TODO: implement completion of MULT");
                off = f - `NUM_FU_ALU;
                c_out.c_en[off]         |= 1;
                c_out.c_ts[off]         |= mul_outs.dst[off].tag;
                c_out.c_rob_idxs[off]   |= mul_outs.dst[off].rob_idx;
                c_out.c_data[off]       |= mul_outs.res[off];
            end
        end

        prf_out = '0;
        for (int unsigned i = 0; i < `NUM_FU_ALU; ++i) begin
            if (!alu_ins.bsy[i])
                continue;
            prf_out.prf_en[i]   = 1;
            prf_out.s_t1s[i]    = alu_ins.dat[i].t1; 
            prf_out.s_t2s[i]    = alu_ins.dat[i].t2; 
        end
        for (int unsigned i = 0; i < `NUM_FU_MULT; ++i) begin
            if (!mul_ins.bsy[i])
                continue;
            prf_out.prf_en[i + `NUM_FU_ALU]   = 1;
            prf_out.s_t1s[i + `NUM_FU_ALU]    = mul_ins.dat[i].t1; 
            prf_out.s_t2s[i + `NUM_FU_ALU]    = mul_ins.dat[i].t2; 
        end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            alu_ins     <= '0;
            mul_ins     <= '0;

            alu_outs    <= '0;
            mul_outs    <= '0;
        end else begin

            for (int i = 0; i < `NUM_FU_ALU; ++i) begin
                if (alu_ins.bsy[i] && !alu_outs.rdy[i]) begin
                    alu_outs.rdy[i] <= 1;
                    alu_outs.res[i] <= alu_res_n[i];
                    alu_outs.dst[i] <= '{
                        tag     :   alu_ins.dat[i].t,
                        rob_idx :   alu_ins.dat[i].rob_idx
                    };
                end else begin
                    alu_ins.bsy[i] <= alu_ins.bsy[i]
                        ? !(alu_outs.rdy[i] && cpl_gnt[i]) // if busy, did it complete
                        : rs_in.fu_vld_alu[i];             // if not busy, did it issue?
                    alu_ins.dat[i] <= rs_in.fu_vld_alu[i]
                        ? rs_in.fu_dat_alu[i]
                        : alu_ins.dat[i];
                    alu_outs.rdy[i] <= alu_outs.rdy[i] && !cpl_gnt[i];
                end
            end

            for (int i = 0; i < `NUM_FU_MULT; ++i) begin
                mul_outs.rdy[i] <= mul_vld_n[i];
                if (mul_vld_n[i]) begin
                    mul_outs.dst[i] <= mul_dst_n[i];
                    mul_outs.res[i] <= mul_res_n[i];
                end

                mul_ins.bsy[i] <= mul_ins.bsy[i]
                    // Option 1: clear only when complete (will re-issue the same insn if inputs the same)
                    // ? !(mul_outs.rdy[i] && cpl_gnt[i + `NUM_FU_ALU]) // if busy, did it complete
                    // Option 2: clear as soon as issue done (might overwrite someone ahead)
                    ? 0
                    : rs_in.fu_vld_mult[i];             // if not busy, did it issue?
                mul_ins.dat[i] <= rs_in.fu_vld_mult[i]
                    ? rs_in.fu_dat_mult[i]
                    : mul_ins.dat[i];
            end

            $display("  %3d | rdy_alu: %b  rdy_mult: %b  rdy_store: %b  rdy_load: %b  |  c_en: %b  c_ts: %d %d c_data: %h c_rob_idxs: %d",
                $time,
                rs_out.fu_rdy_alu,
                rs_out.fu_rdy_mult,
                rs_out.fu_rdy_store,
                rs_out.fu_rdy_load,
                c_out.c_en,
                c_out.c_ts[0],
                c_out.c_ts[1],
                c_out.c_data,
                c_out.c_rob_idxs
            );
            $display("  %3d |||| <prf_out> en: %b s_t1s: [%0d, %0d] s_t2s: [%0d, %0d]",
                $time,
                prf_out.prf_en,
                prf_out.s_t1s[1],
                prf_out.s_t1s[0],
                prf_out.s_t2s[1],
                prf_out.s_t2s[0]
            );
            $display("  %3d |||| <prf_in >        s_v1s: [%0d, %0d] s_v2s: [%0d, %0d]",
                $time,
                prf_in.s_v1s[1],
                prf_in.s_v1s[0],
                prf_in.s_v2s[1],
                prf_in.s_v2s[0]
            );

        end
    end

endmodule // stage_ex
