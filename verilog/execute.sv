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

    // <FU>_ins: staging; where just-issued insns wait for 1 cycle to pull their operands
    struct packed {
        logic       [`NUM_FU_ALU-1:0]   rdy;
        ID_RESULT   [`NUM_FU_ALU-1:0]   dat;
    } alu_ins;
    struct packed {
        logic       [`NUM_FU_MULT-1:0]  rdy;
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

    generate
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            // // Instantiate the ALU
            // TODO: These ALU inputs were kinda hardcoded. Need mux stuff to select which type.
            alu alu_0 ( 
                // Inputs
                .opa(prf_in.s_v1s[i]),
                .opb(prf_in.s_v2s[i]),
                .alu_func(alu_ins.dat[i].alu_func),
                .branch(alu_ins.dat[i].cond_branch), // is this a cond_branch
                .branch_func(3'b011), // Which branch condition to check

                .take(), // True/False condition result (will return FALSE if branch is low)
                .result(alu_res_n[i]) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
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
            fu_rdy_alu      : alu_ins.rdy,
            fu_rdy_mult     : mul_ins.rdy,
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
                // off = f - `NUM_FU_MULT;
                // c_out.c_en[off]         |= 1;
                // c_out.c_ts[off]         |= mul_outs.dst[off].tag;
                // c_out.c_rob_idxs[off]   |= mul_outs.dst[off].rob_idx;
                // c_out.c_data[off]       |= mul_outs.res[off];
            end
        end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            alu_ins     <= '0;
            mul_ins     <= '0; // mark as busy

            alu_outs    <= '0;
            mul_outs    <= '0;
        end else begin
            // foreach (alu_ins.bsy[i]) begin
            for (int i = 0; i < `NUM_FU_ALU; ++i) begin

                if (alu_ins.rdy[i] && !alu_outs.rdy[i]) begin
                    alu_outs.rdy[i] <= 1;
                    alu_outs.res[i] <= alu_res_n[i];
                    alu_outs.dst[i] <= '{
                        tag     :   alu_ins.dat[i].t,
                        rob_idx :   alu_ins.dat[i].rob_idx
                    };
                end else begin
                    alu_ins.rdy[i] <= alu_ins.rdy[i]
                        ? !(alu_outs.rdy[i] && cpl_gnt[i]) // if busy, did it complete
                        : rs_in.fu_vld_alu[i];             // if not busy, did it issue?
                    alu_outs.rdy[i] <= alu_outs.rdy[i] && !cpl_gnt[i];
                end

            end

        end
    end

endmodule // stage_ex
