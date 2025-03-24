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

typedef struct packed {
    PHYS_REG_IDX t;
    ROB_IDX rob_idx;
    DATA data;
} CPL_CAND;

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


module alu_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic [`NUM_FU_ALU-1:0]          ex_rdy,
        // ready to accept from alu_ins?
    input [`NUM_FU_ALU-1:0]                 en,
        // insns to accept from alu_ins
    input struct packed {
        DATA        [`NUM_FU_ALU-1:0]       opa, opb;
        ALU_FUNC    [`NUM_FU_ALU-1:0]       alu_func;
        logic       [`NUM_FU_ALU-1:0][2:0]  branch_func; // Which branch condition to check

        PHYS_REG_IDX [`NUM_FU_ALU-1:0]  t;
        ROB_IDX      [`NUM_FU_ALU-1:0]  rob_idx;
    } ops,
        // insn metadata/operands

    /* BACKEND */
    output logic [`NUM_FU_ALU-1:0]      vld,
    output CPL_CAND [`NUM_FU_ALU-1:0]   cands,
        // completion requests
    input  logic [`NUM_FU_ALU-1:0]      cpl_gnt
        // completion grant
);
    // <FU>_outs: where executed insns wait until completion
    struct packed {
        // ff
        logic   [`NUM_FU_ALU-1:0]   bsy;
        DATA    [`NUM_FU_ALU-1:0]   res;
        DST     [`NUM_FU_ALU-1:0]   dst;
    } outs, outs_n;

    // execute
    generate
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            // // Instantiate the ALU
            // TODO: These ALU inputs were kinda hardcoded. Need mux stuff to select which type.
            alu alu_0 ( 
                // Inputs
                .opa        (ops.opa[i]),
                .opb        (ops.opb[i]),
                .alu_func   (ops.alu_func[i]),
                .branch_func(ops.branch_func[i]), // Which branch condition to check

                .take(), // True/False condition result (will return FALSE if branch is low)
                .result(outs_n.res[i]) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
            );
        end
    endgenerate

    always_comb begin
        vld = outs.bsy;
        foreach (cands[i]) begin
            cands[i] = '{
                t       : outs.dst[i].tag,
                rob_idx : outs.dst[i].rob_idx,
                data    : outs.res[i]
            };
        end

        ex_rdy = ~outs.bsy | cpl_gnt; // complete frees for same-cycle ex acceptances

        outs_n.bsy = en | (outs.bsy & ~cpl_gnt);
        outs_n.dst = outs.dst;
        foreach (outs_n.dst[i]) begin
            if (!en[i])
                continue;
            outs_n.dst[i] = '{
                tag     : ops.t[i],
                rob_idx : ops.rob_idx[i]
            };
        end
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            outs <= '0;
        end else begin
            outs <= outs_n;
        end
    end
endmodule

module mul_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic [`NUM_FU_MULT-1:0]     ex_rdy,
        // ready to accept from mul_ins?
    input [`NUM_FU_MULT-1:0]            en,
        // insns to accept from mul_ins
    input struct packed {
        DATA      [`NUM_FU_MULT-1:0]    rs1, rs2;
        MULT_FUNC [`NUM_FU_MULT-1:0]    func;
        DST       [`NUM_FU_MULT-1:0]    dst;
    } ops,
        // insn metadata/operands

    /* BACKEND */
    output logic [`NUM_FU_MULT-1:0]     vld,
    output CPL_CAND [`NUM_FU_MULT-1:0]  cands,
        // completion requests
    input  logic [`NUM_FU_MULT-1:0]     cpl_gnt
        // completion grant
);
    // <FU>_outs: where executed insns wait until completion
    struct packed {
        // ff
        logic   [`NUM_FU_MULT-1:0]   bsy;
        DATA    [`NUM_FU_MULT-1:0]   res;
        DST     [`NUM_FU_MULT-1:0]   dst;
    } outs, outs_n;

    logic   [`NUM_FU_MULT-1:0]  done;
    DATA    [`NUM_FU_MULT-1:0]  done_res;
    DST     [`NUM_FU_MULT-1:0]  done_dst;

    // execute
    generate
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mults
            // // Instantiate the ALU
            // TODO: These ALU inputs were kinda hardcoded. Need mux stuff to select which type.
            mult mult_0 ( 
                .clock  (clock),
                .reset  (reset),
                .start  (en[i]),
                .dst_in (ops.dst[i]),
                .rs1    (ops.rs1[i]),
                .rs2    (ops.rs2[i]),
                .func   (ops.func[i]), // which mult operation to perform

                // Output
                .dst_out(done_dst[i]),
                .result (done_res[i]),
                .done   (done[i])
            );
        end
    endgenerate

    always_comb begin
        vld = outs.bsy;
        foreach (cands[i]) begin
            cands[i] = '{
                t       : outs.dst[i].tag,
                rob_idx : outs.dst[i].rob_idx,
                data    : outs.res[i]
            };
        end

        ex_rdy = ~outs.bsy | (done & cpl_gnt);

        outs_n.bsy =
            // If we are already busy, remain busy
            //    until we see done & cpl_gnt
            (outs.bsy & ~(done & cpl_gnt))
            // OR if we are not busy, but a new instruction arrives
            //    we become busy
            | done; // TODO: this is an extremely hacky fix
        outs_n.dst = outs.dst;
        outs_n.res = outs.res;
        for (int unsigned i = 0; i < `NUM_FU_MULT; ++i) begin
            if (!done[i])
                continue;
            outs_n.dst[i] = done_dst[i];
            outs_n.res[i] = done_res[i];
        end
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            outs <= '0;
        end else begin
            outs <= outs_n;
        end
    end
endmodule

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
        logic       [`NUM_FU_MULT-1:0]  bsy;
        ID_RESULT   [`NUM_FU_MULT-1:0]  dat;
    } mul_ins;

    // request operands from PRF
    always_comb begin
        prf_out = '0;
        // TODO: not all bsy/busy insns require PRF reads. Maybe enable prf_en iff
        // opa_select == OPA_IS_RS1 || opb OPB_IS_RS2 ?
        foreach (alu_ins.dat[i]) begin
            if (!alu_ins.bsy[i])
                continue;
            prf_out.prf_en[i]   = 1;
            prf_out.s_t1s[i]    = alu_ins.dat[i].t1; 
            prf_out.s_t2s[i]    = alu_ins.dat[i].t2; 
        end
        foreach (mul_ins.dat[i]) begin
            if (!mul_ins.bsy[i])
                continue;
            prf_out.prf_en[i + `NUM_FU_ALU]   = 1;
            prf_out.s_t1s[i + `NUM_FU_ALU]    = mul_ins.dat[i].t1; 
            prf_out.s_t2s[i + `NUM_FU_ALU]    = mul_ins.dat[i].t2; 
        end
    end

    // receive/decode operands from PRF
    struct packed {
        DATA        [`NUM_FU_ALU-1:0]       opa, opb;
        ALU_FUNC    [`NUM_FU_ALU-1:0]       alu_func;
        logic       [`NUM_FU_ALU-1:0][2:0]  branch_func; // Which branch condition to check
        // 
        PHYS_REG_IDX [`NUM_FU_ALU-1:0]  t;
        ROB_IDX      [`NUM_FU_ALU-1:0]  rob_idx;
    } alu_ops;
    struct packed {
        DATA        [`NUM_FU_MULT-1:0]      rs1, rs2;
        MULT_FUNC   [`NUM_FU_MULT-1:0]      func;
        DST         [`NUM_FU_MULT-1:0]      dst;
    } mul_ops;
    always_comb begin
        alu_ops = '0;
        foreach(alu_ins.dat[i]) begin
            if(!alu_ins.bsy[i]) 
                continue;

            // ALU opA mux
            case (alu_ins.dat[i].opa_select)
                OPA_IS_RS1:  alu_ops.opa[i] = prf_in.s_v1s[i];
                OPA_IS_NPC:  alu_ops.opa[i] = alu_ins.dat[i].NPC;
                OPA_IS_PC:   alu_ops.opa[i] = alu_ins.dat[i].PC;
                OPA_IS_ZERO: alu_ops.opa[i] = 0;
                default:     alu_ops.opa[i]= 32'hdeadface; // dead face
            endcase

            // ALU opB mux
            case (alu_ins.dat[i].opb_select)
                OPB_IS_RS2:   alu_ops.opb[i] =  prf_in.s_v2s[i];
                OPB_IS_I_IMM: alu_ops.opb[i] = `RV32_signext_Iimm(alu_ins.dat[i].inst);
                OPB_IS_S_IMM: alu_ops.opb[i] = `RV32_signext_Simm(alu_ins.dat[i].inst);
                OPB_IS_B_IMM: alu_ops.opb[i] = `RV32_signext_Bimm(alu_ins.dat[i].inst);
                OPB_IS_U_IMM: alu_ops.opb[i] = `RV32_signext_Uimm(alu_ins.dat[i].inst);
                OPB_IS_J_IMM: alu_ops.opb[i] = `RV32_signext_Jimm(alu_ins.dat[i].inst);
                default:      alu_ops.opb[i] = 32'hfacefeed; // face feed
            endcase

            alu_ops.alu_func[i]    = alu_ins.dat[i].alu_func;
            alu_ops.branch_func[i] = alu_ins.dat[i].inst.b.funct3;
            alu_ops.t[i]           = alu_ins.dat[i].t;
            alu_ops.rob_idx[i]     = alu_ins.dat[i].rob_idx;
        end

        mul_ops = '0;
        foreach (mul_ins.dat[i]) begin
            mul_ops.rs1[i] = prf_in.s_v1s[i + `NUM_FU_ALU];
            mul_ops.rs2[i] = prf_in.s_v2s[i + `NUM_FU_ALU];
            mul_ops.func[i] = mul_ins.dat[i].inst.r.funct3;
            mul_ops.dst[i] = '{
                rob_idx : mul_ins.dat[i].rob_idx,
                tag     : mul_ins.dat[i].t
            };
        end
    end


    // structure results into generic cdb candidates array
    localparam NUM_FU_TOTAL = `NUM_FU_ALU + `NUM_FU_MULT;

    CPL_CAND [`NUM_FU_ALU-1:0]  alu_cands;
    CPL_CAND [`NUM_FU_MULT-1:0] mul_cands;
    CPL_CAND [NUM_FU_TOTAL-1:0] all_cands;
    assign all_cands = {
        alu_cands,
        mul_cands
    };
    logic [`NUM_FU_ALU-1:0]  alu_vld;
    logic [`NUM_FU_MULT-1:0] mul_vld;
    logic [NUM_FU_TOTAL-1:0] all_vld;
    assign all_vld = {
        alu_vld,
        mul_vld
    };

    logic [`N-1:0][NUM_FU_TOTAL-1:0] cdb2fu_gbus;
    struct packed {
        logic [`NUM_FU_ALU-1:0]  alu;
        logic [`NUM_FU_MULT-1:0] mul;
    } cpl_gnt;

    logic [`NUM_FU_ALU-1:0] alu_ex_rdy;
    logic [`NUM_FU_ALU-1:0] alu_ex_en;
    assign alu_ex_en = alu_ins.bsy & alu_ex_rdy;
    alu_ex alu_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .en     (alu_ex_en),
        .ops    (alu_ops),
        .ex_rdy (alu_ex_rdy),

        .vld    (alu_vld),
        .cands  (alu_cands),
        .cpl_gnt(cpl_gnt.alu)
    );

    logic [`NUM_FU_MULT-1:0] mul_ex_rdy;
    logic [`NUM_FU_MULT-1:0] mul_ex_en;
    assign mul_ex_en = mul_ins.bsy & mul_ex_rdy;
    mul_ex mul_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .en     (mul_ex_en),
        .ops    (mul_ops),
        .ex_rdy (mul_ex_rdy),

        .vld    (mul_vld),
        .cands  (mul_cands),
        .cpl_gnt(cpl_gnt.mul)
    );

    psel_gen #(
        .WIDTH(NUM_FU_TOTAL),
        .REQS(`N)
    ) sel_cpl (
        .req(all_vld),
        .gnt(cpl_gnt),      // type coercion: logic [NUM_FU_TOTAL-1:0] -> {logic [`NUM_FU_ALU-1:0] alu, logic [`NUM_FU_MULT-1:0] mul}
        .gnt_bus(cdb2fu_gbus)
    );

    always_comb begin
        rs_out = '{
            fu_rdy_alu      : ~alu_ins.bsy | alu_ex_en,
            fu_rdy_mult     : ~mul_ins.bsy | mul_ex_en,
            fu_rdy_load     : '0,
            fu_rdy_store    : '0
        };

        c_out = '0;
        foreach (cdb2fu_gbus[c, f]) begin
            if (cdb2fu_gbus[c][f]) begin
                c_out.c_en[c]           |= 1;
                c_out.c_ts[c]           |= all_cands[f].t;
                c_out.c_rob_idxs[c]     |= all_cands[f].rob_idx;
                c_out.c_data[c]         |= all_cands[f].data;
            end
        end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            alu_ins     <= '0;
            mul_ins     <= '0;
        end else begin
            alu_ins.bsy <= rs_in.fu_vld_alu | (alu_ins.bsy & ~alu_ex_en);
            for (int i = 0; i < `NUM_FU_ALU; ++i) begin
                if (rs_in.fu_vld_alu[i])
                    alu_ins.dat[i] <= rs_in.fu_dat_alu[i];
            end

            mul_ins.bsy <= rs_in.fu_vld_mult | (mul_ins.bsy & ~mul_ex_en);
            for (int i = 0; i < `NUM_FU_MULT; ++i) begin
                if (rs_in.fu_vld_mult[i])
                    mul_ins.dat[i] <= rs_in.fu_dat_mult[i];
            end

            $display("  %3d | >> EXECUTE", $time);
            $display("rdy_alu: %b  rdy_mult: %b  rdy_store: %b  rdy_load: %b  |  c_en: [%b %b] c_ts: [%d %d] c_data: [%h %h] c_rob_idxs: [%d %d] cpl_gnt: %b",
                rs_out.fu_rdy_alu,
                rs_out.fu_rdy_mult,
                rs_out.fu_rdy_store,
                rs_out.fu_rdy_load,
                c_out.c_en[0],
                c_out.c_en[1],
                c_out.c_ts[0],
                c_out.c_ts[1],
                c_out.c_data[0],
                c_out.c_data[1],
                c_out.c_rob_idxs[0],
                c_out.c_rob_idxs[1],
                cpl_gnt
            );
            // for (int i = 0; i < 4; ++i) begin
            //     $display("all_vld[%0d]: %b", i, all_vld[i]);
            // end
            // $display("all_vld: %b", all_vld);
            // $display("");
            // for (int i = 0; i < 4; ++i) begin
            //     $display("cpl_gnt[%0d]: %b", i, cpl_gnt[i]);
            // end
            // $display("cpl_gnt: %b", cpl_gnt);
            // $display("");
            // for (int c = 0; c < 2; ++c) begin
            //     for (int f = 0; f < 4; ++f) begin
            //         $display("cdb2fu_gbus[%0d][%0d]: %b", c, f, cdb2fu_gbus[c][f]);
            //     end
            // end
            // $display("");
            // for (int i = 0; i < 4; ++i) begin
            //     $display("cand[%0d]: t: %0d rob_idx: %0d data: %x", i, all_cands[i].t, all_cands[i].rob_idx, all_cands[i].data);
            // end
            // $display("<prf_out> en: %b s_t1s: [%0d, %0d, %0d, %0d] s_t2s: [%0d, %0d, %0d, %0d]",
            //     prf_out.prf_en,
            //     prf_out.s_t1s[0],
            //     prf_out.s_t1s[1],
            //     prf_out.s_t1s[2],
            //     prf_out.s_t1s[3],
            //     prf_out.s_t2s[0],
            //     prf_out.s_t2s[1],
            //     prf_out.s_t2s[2],
            //     prf_out.s_t2s[3]
            // );
            // $display("alu: (rdy: %b, res: %x), (rdy: %b, res: %x), mul: (rdy: %b, res: %x), (rdy: %b, res: %x)",
            //     alu_outs.rdy[0],
            //     alu_outs.res[0],
            //     alu_outs.rdy[1],
            //     alu_outs.res[1],
            //     mul_outs.rdy[0],
            //     mul_outs.res[0],
            //     mul_outs.rdy[1],
            //     mul_outs.res[1]
            // );
            $display("<prf_in >        s_v1s: [%0d, %0d, %0d, %0d] s_v2s: [%0d, %0d, %0d, %0d]",
                prf_in.s_v1s[0],
                prf_in.s_v1s[1],
                prf_in.s_v1s[2],
                prf_in.s_v1s[3],
                prf_in.s_v2s[0],
                prf_in.s_v2s[1],
                prf_in.s_v2s[2],
                prf_in.s_v2s[3]
            );
            $display("  %3d | << EXECUTE", $time);

        end
    end

endmodule // stage_ex
