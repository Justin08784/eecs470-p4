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
        logic   [`NUM_FU_MULT-1:0]  bsy;
        logic   [`NUM_FU_MULT-1:0]  dat;
    } mul_ins;

    // <FU>_outs: where executed insns wait until completion
    struct packed {
        // ff
        logic   [`NUM_FU_ALU-1:0]   rdy;
        DATA    [`NUM_FU_ALU-1:0]   res;
        DST     [`NUM_FU_ALU-1:0]   dst;
        // comb
        logic   [`NUM_FU_ALU-1:0]   cpl;
    } alu_outs;
    struct packed {
        // ff
        logic   [`NUM_FU_MULT-1:0]  rdy;
        DATA    [`NUM_FU_MULT-1:0]  res;
        DST     [`NUM_FU_MULT-1:0]  dst;
        // comb
        logic   [`NUM_FU_MULT-1:0]  cpl;
    } mul_outs;

    localparam NUM_FU_TOTAL = `NUM_FU_ALU + `NUM_FU_MULT;
    logic [NUM_FU_TOTAL-1:0] all_cpl;
    always_comb begin
        rs_out = '{
            // fu_rdy_alu      : ~alu_ins.bsy,
            // fu_rdy_mult     : ~mul_ins.bsy,
            fu_rdy_alu      : '0,
            fu_rdy_mult     : '0,
            fu_rdy_load     : '0,
            fu_rdy_store    : '0
        };

        all_cpl = {
            mul_outs.cpl,
            alu_outs.cpl
        };
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            alu_ins     <= '0;
            mul_ins     <= '1; // mark as busy

            alu_outs    <= '0;
            mul_outs    <= '0;
        end else begin
            alu_outs    <= '0;
            alu_ins     <= '0;
            // foreach (alu_ins.bsy[i]) begin
            for (int i = 0; i < `NUM_FU_ALU; ++i) begin
                alu_ins.bsy[i] <= alu_ins.bsy[i]
                    ? !(alu_outs.rdy[i] && alu_outs.cpl[i]) // if busy, did it complete
                    : rs_in.fu_vld_alu[i];                  // if not busy, did it issue?
            end
            $display("alu: %b", alu_outs.cpl);
            $display("mul: %b", mul_outs.cpl);
            $display("all: %b", all_cpl);
            $display("yoo: %b %b", alu_ins.bsy, mul_ins.bsy);
            $display("ding: %b", rs_in.fu_vld_alu);
            $display("");
        end
    end

endmodule // stage_ex
