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

module alu_group (
    input clock,
    input reset,
    input flush,

    output logic        [`NUM_FU_ALU-1:0] ins_rdy,
    input  logic        [`NUM_FU_ALU-1:0] ins_en, // sender-side (RS issue) enable
    input  ID_RESULT    [`NUM_FU_ALU-1:0] ins_dat,
    rs2execute          rs_in,

    struct packed {
        logic           [`NUM_FU_ALU-1:0] prf_en;
        PHYS_REG_IDX    [`NUM_FU_ALU-1:0] s_t1s;
        PHYS_REG_IDX    [`NUM_FU_ALU-1:0] s_t2s;
    } alu2prf,
    struct packed {
        DATA            [`NUM_FU_ALU-1:0] s_v1s;
        DATA            [`NUM_FU_ALU-1:0] s_v2s;
    } prf2alu,

    output  logic       [`NUM_FU_ALU-1:0] outs_vld, // equivalent of alu_outs.rdy; yes I renamed
    output  DATA        [`NUM_FU_ALU-1:0] outs_res,
    output  DST         [`NUM_FU_ALU-1:0] outs_dst,
    input   logic       [`NUM_FU_ALU-1:0] outs_en   // receiver-side (execute completion) enable
);
    struct packed {
        DATA [`NUM_FU_ALU-1:0] opa, opb;
    } ops;

    // <FU>_ins: staging; where just-issued insns wait for 1 cycle to pull their operands
    struct packed {
        logic     [`NUM_FU_ALU-1:0] bsy;
        logic     [`NUM_FU_ALU-1:0] en;
        ID_RESULT [`NUM_FU_ALU-1:0] dat;
    } ins;

    // <FU>_outs: where executed insns wait until completion
    struct packed {
        logic [`NUM_FU_ALU-1:0] vld;
        DATA  [`NUM_FU_ALU-1:0] res;
        DST   [`NUM_FU_ALU-1:0] dst;
        logic [`NUM_FU_ALU-1:0] en;
    } outs;

    DATA [`NUM_FU_ALU-1:0] alu_res_n;

    assign ins_rdy = ~ins.bsy;

    // extract ALU operands
    always_comb begin
        foreach(ins.dat[i]) begin
            if(!ins.bsy[i]) 
                continue;

            // ALU opA mux
            case (ins.dat[i].opa_select)
                OPA_IS_RS1:  ops.opa[i] = prf2alu.s_v1s[i];
                OPA_IS_NPC:  ops.opa[i] = ins.dat[i].NPC;
                OPA_IS_PC:   ops.opa[i] = ins.dat[i].PC;
                OPA_IS_ZERO: ops.opa[i] = 0;
                default:     ops.opa[i]= 32'hdeadface; // dead face
            endcase

            // ALU opB mux
            case (ins.dat[i].opb_select)
                OPB_IS_RS2:   ops.opb[i] =  prf2alu.s_v2s[i];
                OPB_IS_I_IMM: ops.opb[i] = `RV32_signext_Iimm(ins.dat[i].inst);
                OPB_IS_S_IMM: ops.opb[i] = `RV32_signext_Simm(ins.dat[i].inst);
                OPB_IS_B_IMM: ops.opb[i] = `RV32_signext_Bimm(ins.dat[i].inst);
                OPB_IS_U_IMM: ops.opb[i] = `RV32_signext_Uimm(ins.dat[i].inst);
                OPB_IS_J_IMM: ops.opb[i] = `RV32_signext_Jimm(ins.dat[i].inst);
                default:      ops.opb[i] = 32'hfacefeed; // face feed
            endcase

        end
    end


    generate
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            // // Instantiate the ALU
            // TODO: These ALU inputs were kinda hardcoded. Need mux stuff to select which type.
            alu alu_0 ( 
                // Inputs
                .opa(ops.opa[i]),
                .opb(ops.opb[i]),
                .alu_func   (ins.dat[i].alu_func),
                .branch_func(ins.dat[i].inst.b.funct3), // Which branch condition to check

                .take(), // True/False condition result (will return FALSE if branch is low)
                .result(alu_res_n[i]) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
            );
        end
    endgenerate

    // always_ff @(posedge clock) begin
    //     if (reset || flush) begin
    //         ins  <= '0;
    //         outs <= '0;
    //     end else begin

    //         for (int i = 0; i < `NUM_FU_ALU; ++i) begin
    //             if (ins.bsy[i] && !outs.vld[i]) begin
    //                 outs.vld[i] <= 1;
    //                 outs.res[i] <= alu_res_n[i];
    //                 outs.dst[i] <= '{
    //                     tag     :   ins.dat[i].t,
    //                     rob_idx :   ins.dat[i].rob_idx
    //                 };
    //             end else begin
    //                 ins.bsy[i] <= ins.bsy[i]
    //                     ? !(outs.vld[i] && cpl_gnt.alu[i]) // if busy, did it complete
    //                     : rs_in.fu_vld_alu[i];             // if not busy, did it issue?
    //                 ins.dat[i] <= rs_in.fu_vld_alu[i]
    //                     ? rs_in.fu_dat_alu[i]
    //                     : ins.dat[i];
    //                 outs.vld[i] <= outs.vld[i] && !cpl_gnt.alu[i];
    //             end
    //         end
    //     end
    // end

endmodule

module mul_group (
    input clock,
    input reset,
    input flush,

    output logic        [`NUM_FU_ALU-1:0] ins_rdy,
    input  logic        [`NUM_FU_ALU-1:0] ins_en, // sender-side (RS issue) enable
    input  ID_RESULT    [`NUM_FU_ALU-1:0] ins_dat,
    rs2execute          rs_in,

    struct packed {
        logic           [`NUM_FU_ALU-1:0] prf_en;
        PHYS_REG_IDX    [`NUM_FU_ALU-1:0] s_t1s;
        PHYS_REG_IDX    [`NUM_FU_ALU-1:0] s_t2s;
    } mul2prf,
    struct packed {
        DATA            [`NUM_FU_ALU-1:0] s_v1s;
        DATA            [`NUM_FU_ALU-1:0] s_v2s;
    } prf2mul,

    output  logic       [`NUM_FU_ALU-1:0] outs_vld, // equivalent of alu_outs.rdy; yes I renamed
    output  DATA        [`NUM_FU_ALU-1:0] outs_res,
    output  DST         [`NUM_FU_ALU-1:0] outs_dst,
    input   logic       [`NUM_FU_ALU-1:0] outs_en   // receiver-side (execute completion) enable
);
    DATA [`NUM_FU_MULT-1:0] mul_res_n;
    DST     [`NUM_FU_MULT-1:0] mul_dst_n;
    logic   [`NUM_FU_MULT-1:0] mul_vld_n;

    // <FU>_ins: staging; where just-issued insns wait for 1 cycle to pull their operands
    struct packed {
        logic     [`NUM_FU_MULT-1:0] bsy;
        logic     [`NUM_FU_MULT-1:0] en;
        ID_RESULT [`NUM_FU_MULT-1:0] dat;
    } ins;

    // <FU>_outs: where executed insns wait until completion
    struct packed {
        logic [`NUM_FU_MULT-1:0] vld;
        DATA  [`NUM_FU_MULT-1:0] res;
        DST   [`NUM_FU_MULT-1:0] dst;
        logic [`NUM_FU_MULT-1:0] en;
    } outs;

    assign ins_rdy = ~ins.bsy;

    generate
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mults
            // // Instantiate the ALU
            // TODO: These ALU inputs were kinda hardcoded. Need mux stuff to select which type.
            mult mult_0 ( 
                .clock(clock),
                .reset(reset),
                .start(ins.bsy[i]),
                .dst_in('{
                    rob_idx : ins.dat[i].rob_idx,
                    tag     : ins.dat[i].t
                }),
                .rs1(prf2mul.s_v1s[i + `NUM_FU_ALU]),
                .rs2(prf2mul.s_v2s[i + `NUM_FU_ALU]),
                .func(ins.dat[i].inst.r.funct3), // which mult operation to perform

                // Output
                .dst_out(mul_dst_n[i]),
                .result (mul_res_n[i]),
                .done   (mul_vld_n[i])
            );
        end
    endgenerate

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            ins     <= '0;
            outs    <= '0;
        end else begin
            for (int i = 0; i < `NUM_FU_MULT; ++i) begin
                outs.vld[i] <= mul_vld_n[i];
                if (mul_vld_n[i]) begin
                    outs.dst[i] <= mul_dst_n[i];
                    outs.res[i] <= mul_res_n[i];
                end

                ins.bsy[i] <= ins.bsy[i]
                    // Option 1: clear only when complete (will re-issue the same insn if inputs the same)
                    // ? !(outs.vld[i] && cpl_gnt[i + `NUM_FU_ALU]) // if busy, did it complete
                    // Option 2: clear as soon as issue done (might overwrite someone ahead)
                    ? 0
                    : rs_in.fu_vld_mult[i];             // if not busy, did it issue?
                ins.dat[i] <= rs_in.fu_vld_mult[i]
                    ? rs_in.fu_dat_mult[i]
                    : ins.dat[i];
            end
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
    localparam NUM_FU_TOTAL = `NUM_FU_ALU + `NUM_FU_MULT;
    struct packed {
        logic [`NUM_FU_ALU-1:0]  alu;
        logic [`NUM_FU_MULT-1:0] mul;
    } outs_vld;
    struct packed {
        DATA  [`NUM_FU_ALU-1:0]  alu;
        DATA  [`NUM_FU_MULT-1:0] mul;
    } outs_res;
    struct packed {
        DST   [`NUM_FU_ALU-1:0]  alu;
        DST   [`NUM_FU_MULT-1:0] mul;
    } outs_dst;
    struct packed {
        logic [`NUM_FU_ALU-1:0]  alu;
        logic [`NUM_FU_MULT-1:0] mul;
    } outs_en;

    alu_group alu_group0 (
        .clock(clock),
        .reset(reset),
        .flush(flush),

        .ins_rdy(rs_out.fu_rdy_alu),
        .ins_en (rs_in.fu_vld_alu),
        .ins_dat(rs_in.fu_dat_alu),

        // TODO: change this to struct access; dont want indexing magic
        .alu2prf('{
            prf_out.prf_en[`NUM_FU_ALU-1:0],
            prf_out.s_t1s[`NUM_FU_ALU-1:0],
            prf_out.s_t2s[`NUM_FU_ALU-1:0]
        }),
        .prf2alu('{
            prf_in.s_v1s[`NUM_FU_ALU-1:0],
            prf_in.s_v2s[`NUM_FU_ALU-1:0]
        }),

        // .outs_vld(outs_vld.alu),
        // .outs_res(outs_res.alu),
        // .outs_dst(outs_dst.alu),
        // .outs_en (outs_en.alu)
        // TODO: build a outs struct here to comb. sample outgoing stuff
        .outs_vld(outs_vld.alu),
        .outs_res(outs_res.alu),
        .outs_dst(outs_dst.alu),
        .outs_en (outs_en.alu)
    );

    assign rs_out.fu_rdy_load   = '0;
    assign rs_out.fu_rdy_store  = '0;

    typedef struct packed {
        logic [`NUM_FU_ALU-1:0]     alu;
        logic [`NUM_FU_MULT-1:0]    mul;
    } FU_rdy;
    FU_rdy outs_rdy;
    assign outs_rdy = '{
        alu:outs_vld.alu,
        mul:outs_vld.mul
    };

    FU_rdy cpl_gnt;
    FU_rdy [`N-1:0] cdb2fu_gbus;
    psel_gen #(
        .WIDTH(NUM_FU_TOTAL),
        .REQS(`N)
    ) sel_cpl (
        .req(outs_rdy),         // coercion: FU_rdy -> logic [`NUM_FU_TOTAL-1:0]
        .gnt(cpl_gnt),          // coercion: logic [`NUM_FU_TOTAL-1:0] -> FU_rdy
        .gnt_bus(cdb2fu_gbus)   // coercion: logic [`N-1:0][`NUM_FU_TOTAL-1:0] -> FU_rdy [`N-1:0]
    );

    int unsigned off;
    always_comb begin
        c_out = '0;
        foreach (cdb2fu_gbus[c]) begin
            for (int unsigned a_i = 0; a_i < `NUM_FU_ALU; ++a_i) begin
                if (cdb2fu_gbus[c].alu[a_i]) begin
                    c_out.c_en[c]           |= 1;
                    c_out.c_ts[c]           |= outs_dst.alu[a_i].tag;
                    c_out.c_rob_idxs[c]     |= outs_dst.alu[a_i].rob_idx;
                    c_out.c_data[c]         |= outs_res.alu[a_i];
                end
            end

            for (int unsigned m_i = 0; m_i < `NUM_FU_MULT; ++m_i) begin
                if (cdb2fu_gbus[c].mul[m_i]) begin
                    c_out.c_en[c]           |= 1;
                    c_out.c_ts[c]           |= outs_dst.mul[m_i].tag;
                    c_out.c_rob_idxs[c]     |= outs_dst.mul[m_i].rob_idx;
                    c_out.c_data[c]         |= outs_res.mul[m_i];
                end
            end
        end

        // prf_out = '0;
        // for (int unsigned i = 0; i < `NUM_FU_ALU; ++i) begin
        //     if (!alu_ins.bsy[i])
        //         continue;
        //     prf_out.prf_en[i]   = 1;
        //     prf_out.s_t1s[i]    = alu_ins.dat[i].t1; 
        //     prf_out.s_t2s[i]    = alu_ins.dat[i].t2; 
        // end
        // for (int unsigned i = 0; i < `NUM_FU_MULT; ++i) begin
        //     if (!mul_ins.bsy[i])
        //         continue;
        //     prf_out.prf_en[i + `NUM_FU_ALU]   = 1;
        //     prf_out.s_t1s[i + `NUM_FU_ALU]    = mul_ins.dat[i].t1; 
        //     prf_out.s_t2s[i + `NUM_FU_ALU]    = mul_ins.dat[i].t2; 
        // end
    end


    // always_ff @(posedge clock) begin
    //     if (reset || flush) begin
    //         alu_ins     <= '0;
    //         mul_ins     <= '0;

    //         alu_outs    <= '0;
    //         mul_outs    <= '0;
    //     end else begin
    //         $display("  %3d | >> EXECUTE", $time);
    //         $display("rdy_alu: %b  rdy_mult: %b  rdy_store: %b  rdy_load: %b  |  c_en: [%b %b] c_ts: [%d %d] c_data: [%h %h] c_rob_idxs: [%d %d] cpl_gnt: %b",
    //             rs_out.fu_rdy_alu,
    //             rs_out.fu_rdy_mult,
    //             rs_out.fu_rdy_store,
    //             rs_out.fu_rdy_load,
    //             c_out.c_en[0],
    //             c_out.c_en[1],
    //             c_out.c_ts[0],
    //             c_out.c_ts[1],
    //             c_out.c_data[0],
    //             c_out.c_data[1],
    //             c_out.c_rob_idxs[0],
    //             c_out.c_rob_idxs[1],
    //             cpl_gnt
    //         );
    //         $display("<prf_out> en: %b s_t1s: [%0d, %0d, %0d, %0d] s_t2s: [%0d, %0d, %0d, %0d]",
    //             prf_out.prf_en,
    //             prf_out.s_t1s[0],
    //             prf_out.s_t1s[1],
    //             prf_out.s_t1s[2],
    //             prf_out.s_t1s[3],
    //             prf_out.s_t2s[0],
    //             prf_out.s_t2s[1],
    //             prf_out.s_t2s[2],
    //             prf_out.s_t2s[3]
    //         );
    //         $display("alu: (rdy: %b, res: %x), (rdy: %b, res: %x), mul: (rdy: %b, res: %x), (rdy: %b, res: %x)",
    //             outs_vld.alu[0],
    //             outs_res.alu[0],
    //             outs_vld.alu[1],
    //             outs_res.alu[1],
    //             outs_vld.mul[0],
    //             outs_res.mul[0],
    //             outs_vld.mul[1],
    //             outs_res.mul[1]
    //         );
    //         $display("<prf_in >        s_v1s: [%0d, %0d] s_v2s: [%0d, %0d]",
    //             prf_in.s_v1s[0],
    //             prf_in.s_v1s[1],
    //             prf_in.s_v2s[0],
    //             prf_in.s_v2s[1]
    //         );
    //         $display("  %3d | << EXECUTE", $time);

    //     end
    // end

endmodule // stage_ex
