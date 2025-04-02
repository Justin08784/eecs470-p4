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

/*
Flow chart
[Reservation Station] 
     ↓
[Staging FIFO (s_buf)]  ← just buffers instruction for 1 cycle
     ↓
[ops register (alu_ops, mul_ops)]  ← PRF values fetched here
     ↓
[Functional Unit (ALU or MUL)]
     ↓
[Completion FIFO (cpl_buf)] ← waits for CDB slot
     ↓
[ CDB Output Reg (c_out) ] ← selected for writeback this cycle
*/

typedef struct packed {
    PHYS_REG_IDX t;
    ROB_IDX rob_idx;
    DATA data;
    BTQ_IDX btq_idx;
    logic take;
    logic is_brch;
} CPL_CAND;

typedef struct packed {
    CPL_CAND [`NUM_FU_ALU-1:0]  alu;
    CPL_CAND [`NUM_FU_MULT-1:0] mul;
} CPL_CAND_BY_FU;

typedef struct packed {
    ID_RESULT [`NUM_FU_ALU-1:0]  alu;
    ID_RESULT [`NUM_FU_MULT-1:0] mul;
} ID_RESULT_BY_FU;

/* Slices (or "views") of ID_RESULT needed for each FU type */
typedef struct packed {
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;
    BTQ_IDX         btq_idx;

    INST inst;
    ADDR PC;
    ADDR NPC;

    ALU_OPA_SELECT opa_select;
    ALU_OPB_SELECT opb_select;
    ALU_FUNC alu_func;
    logic    cond_branch;
    logic    uncond_branch;
} ID_ALU_VIEW;

typedef struct packed {
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    ROB_IDX         rob_idx;
    logic[2:0]      func;
} ID_MUL_VIEW;

/* Operand data needed for each FU type */
typedef struct packed {
    logic       [`NUM_FU_ALU-1:0]       bsy; // unused; same as en
    DATA        [`NUM_FU_ALU-1:0]       opa, opb;
    DATA        [`NUM_FU_ALU-1:0]       rs1, rs2;
    ALU_FUNC    [`NUM_FU_ALU-1:0]       alu_func;
    logic       [`NUM_FU_ALU-1:0][2:0]  branch_func; // Which branch condition to check
    logic       [`NUM_FU_ALU-1:0]       cond_branch;
    logic       [`NUM_FU_ALU-1:0]       uncond_branch;

    PHYS_REG_IDX    [`NUM_FU_ALU-1:0]   t;
    ROB_IDX         [`NUM_FU_ALU-1:0]   rob_idx;
    BTQ_IDX         [`NUM_FU_ALU-1:0]   btq_idx;
} ALU_OPS;

typedef struct packed {
    logic       [`NUM_FU_MULT-1:0]      bsy;
    DATA        [`NUM_FU_MULT-1:0]      rs1, rs2;
    MULT_FUNC   [`NUM_FU_MULT-1:0]      func;
    DST         [`NUM_FU_MULT-1:0]      dst;
} MUL_OPS;

// ALU: computes the result of FUNC applied with operands A and B
// This module is purely combinational
module alu (
    input DATA      opa,
    input DATA      opb,
    input DATA      rs1,
    input DATA      rs2,
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
            3'b000:  take = signed'(rs1) == signed'(rs2); // BEQ
            3'b001:  take = signed'(rs1) != signed'(rs2); // BNE
            3'b100:  take = signed'(rs1) <  signed'(rs2); // BLT
            3'b101:  take = signed'(rs1) >= signed'(rs2); // BGE
            3'b110:  take = rs1 <  rs2;                    // BLTU
            3'b111:  take = rs1 >= rs2;                   // BGEU
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
    ALU_OPS ops,
        // insn metadata/operands

    /* BACKEND */
    output logic [`NUM_FU_ALU-1:0]      vld,
    output CPL_CAND [`NUM_FU_ALU-1:0]   cands,
        // completion requests
    input  logic [`NUM_FU_ALU-1:0]      cpl_gnt
        // completion grant
);
    // execute
    generate
        CPL_CAND    [`NUM_FU_ALU-1:0] tmp_data;
        DATA        [`NUM_FU_ALU-1:0] tmp_res;
        logic       [`NUM_FU_ALU-1:0] tmp_take;
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            alu alu_0 ( 
                // Inputs
                .opa        (ops.opa[i]),
                .opb        (ops.opb[i]),
                .rs1        (ops.rs1[i]),
                .rs2        (ops.rs2[i]),
                .alu_func   (ops.alu_func[i]),
                .branch_func(ops.branch_func[i]), // Which branch condition to check

                .take(tmp_take[i]), // True/False condition result (will return FALSE if branch is low)
                .result(tmp_res[i]) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
            );

            assign tmp_data[i] = '{
                t       : ops.t[i],
                rob_idx : ops.rob_idx[i],
                data    : tmp_res[i],
                btq_idx : ops.btq_idx[i],
                take    : tmp_take[i],
                is_brch : ops.cond_branch[i] || ops.uncond_branch[i]
            };

            // <FU>_outs: where executed insns wait until completion
            ppln_skid #(
                .WIDTH($bits(CPL_CAND))
            ) cpl_buf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (en[i]),
                .i_rdy (ex_rdy[i]),
                .i_dat (tmp_data[i]),

                .o_vld (vld[i]),
                .o_rdy (cpl_gnt[i]),
                .o_dat (cands[i])
            );
        end
    endgenerate
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
    MUL_OPS ops,
        // insn metadata/operands

    /* BACKEND */
    output logic [`NUM_FU_MULT-1:0]     vld,
    output CPL_CAND [`NUM_FU_MULT-1:0]  cands,
        // completion requests
    input  logic [`NUM_FU_MULT-1:0]     cpl_gnt
        // completion grant
);
    // execute
    generate
        logic       [`NUM_FU_MULT-1:0] tmp_out_vld;
        DATA        [`NUM_FU_MULT-1:0] tmp_res;
        DST         [`NUM_FU_MULT-1:0] tmp_dst;
        CPL_CAND    [`NUM_FU_MULT-1:0] tmp_data;

        logic       [`NUM_FU_MULT-1:0] cpl_buf_rdy;
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mults
            mult mult_0 ( 
                .clock  (clock),
                .reset  (reset),
                .flush  (flush),
                .in_vld (en[i]),
                .out_rdy(cpl_buf_rdy[i]),
                .dst_in (ops.dst[i]),
                .rs1    (ops.rs1[i]),
                .rs2    (ops.rs2[i]),
                .func   (ops.func[i]),

                // Output
                .dst_out(tmp_dst[i]),
                .result (tmp_res[i]),
                .in_rdy (ex_rdy[i]),
                .out_vld(tmp_out_vld[i])
            );

            assign tmp_data[i] = '{
                t       : tmp_dst[i].tag,
                rob_idx : tmp_dst[i].rob_idx,
                data    : tmp_res[i],
                btq_idx : '0,
                take    : '0,
                is_brch : '0
            };

            // <FU>_outs: where executed insns wait until completion
            ppln_skid #(
                .WIDTH($bits(CPL_CAND))
            ) cpl_buf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (tmp_out_vld[i]),
                .i_dat (tmp_data[i]),
                .i_rdy (cpl_buf_rdy[i]),

                .o_vld (vld[i]),
                .o_rdy (cpl_gnt[i]),
                .o_dat (cands[i])

            );
           
        end
    endgenerate
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
        LOGIC_BY_FU     rdy;
        LOGIC_BY_FU     vld;
        struct packed {
            ID_ALU_VIEW [`NUM_FU_ALU-1:0]   alu;
            ID_MUL_VIEW [`NUM_FU_MULT-1:0]  mul;
        } dat;
    } ins;

    logic [`NUM_FU_ALU-1:0]     alu_ops_rdy;
    logic [`NUM_FU_MULT-1:0]    mul_ops_rdy;
    logic [`NUM_FU_ALU-1:0]     alu_in2ops_en;
    logic [`NUM_FU_MULT-1:0]    mul_in2ops_en;
    generate
        /* Staging buffers (sbufs):

        Size 2 is the minimum FIFO depth (without internal forwarding) that supports
        a 1-write-per-cycle producer and 1-read-per-cycle consumer at steady state
        with no bubbles.

        The point of this staging buffer is to break comb. dependencies between:
            1) backpressure emanating from <FU>_ops_rdy and
            2) issue selection logic in RS
        Adding internal forwarding would defeat its entire purpose.
        */
        // TODO: Make these into FIFOs with only the subset of fields needed
        // for the ALU type. Conserve space.
        assign alu_in2ops_en = ins.vld.alu & alu_ops_rdy;
        assign mul_in2ops_en = ins.vld.mul & mul_ops_rdy;
        ID_ALU_VIEW tmp_alu_el[`NUM_FU_ALU-1:0];
        ID_MUL_VIEW tmp_mul_el[`NUM_FU_MULT-1:0];

        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alu_sbufs
            assign tmp_alu_el[i] = '{
                t       : rs_in.fu_dat_alu[i].t,
                t1      : rs_in.fu_dat_alu[i].t1,
                t2      : rs_in.fu_dat_alu[i].t2,
                rob_idx : rs_in.fu_dat_alu[i].rob_idx,
                btq_idx : rs_in.fu_dat_alu[i].btq_idx,

                inst    : rs_in.fu_dat_alu[i].inst,
                PC      : rs_in.fu_dat_alu[i].PC,
                NPC     : rs_in.fu_dat_alu[i].NPC,

                opa_select  : rs_in.fu_dat_alu[i].opa_select,
                opb_select  : rs_in.fu_dat_alu[i].opb_select,
                alu_func    : rs_in.fu_dat_alu[i].alu_func,
                cond_branch : rs_in.fu_dat_alu[i].cond_branch,
                uncond_branch : rs_in.fu_dat_alu[i].uncond_branch
            };

            ppln_skid #(
                .WIDTH($bits(ID_ALU_VIEW))
            ) cpl_buf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_vld_alu[i]),
                .i_rdy (ins.rdy.alu[i]),
                .i_dat (tmp_alu_el[i]),

                .o_vld (ins.vld.alu[i]),
                .o_rdy (alu_in2ops_en[i]),
                .o_dat (ins.dat.alu[i])
            );
        end
        
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mul_sbufs
            assign tmp_mul_el[i] = '{
                t       : rs_in.fu_dat_mult[i].t,
                t1      : rs_in.fu_dat_mult[i].t1,
                t2      : rs_in.fu_dat_mult[i].t2,
                rob_idx : rs_in.fu_dat_mult[i].rob_idx,
                func    : rs_in.fu_dat_mult[i].inst.r.funct3
            };
            ppln_skid #(
                .WIDTH($bits(ID_MUL_VIEW))
            ) cpl_buf (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_vld_mult[i]),
                .i_rdy (ins.rdy.mul[i]),
                .i_dat (tmp_mul_el[i]),

                .o_vld (ins.vld.mul[i]),
                .o_rdy (mul_in2ops_en[i]),
                .o_dat (ins.dat.mul[i])
            );
            // fifo #(
            //     .DEPTH(2),
            //     .WIDTH($bits(ID_MUL_VIEW)),
            //     .NUM_RPORTS(1),
            //     .NUM_WPORTS(1),
            //     .ENABLE_INTR_FWD(`FALSE)
            // ) s_buf (
            //     .clock      (clock),
            //     .reset      (reset),
            //     .flush      (flush),
            //     .wr_en_cnt  (rs_in.fu_vld_mult[i]),
            //     .wr_data    (tmp_mul_el[i]),
            //     .rd_en_cnt  (mul_in2ops_en[i]),
            //     .rd_data    (ins.dat.mul[i]),

            //     .free_scnt  (ins.rdy.mul[i]),
            //     .used_scnt  (ins.vld.mul[i])
            // );
        end
    endgenerate

    // request operands from PRF (separate stage)
    /*
    TODO: A separate PRF + operand fetch/decode stage is UNACCEPTABLE for performance,
    as it adds 1 cycle delay to waking dependent insns. We MUST move PRF read
    forward to issue, and operand decode into <FU>_ex.
    */
    always_comb begin
        prf_out = '0;
        foreach (alu_in2ops_en[i]) begin
            if (!alu_in2ops_en[i])
                continue;
            prf_out.s_en1s.alu[i]   = 1;
            prf_out.s_en2s.alu[i]   = 1;
            prf_out.s_t1s.alu[i]    = ins.dat.alu[i].t1; 
            prf_out.s_t2s.alu[i]    = ins.dat.alu[i].t2; 
        end
        foreach (mul_in2ops_en[i]) begin
            if (!mul_in2ops_en[i])
                continue;
            prf_out.s_en1s.mul[i]   = 1;
            prf_out.s_en2s.mul[i]   = 1;
            prf_out.s_t1s.mul[i]    = ins.dat.mul[i].t1; 
            prf_out.s_t2s.mul[i]    = ins.dat.mul[i].t2; 
        end
    end

    struct packed {
        LOGIC_BY_FU rdy;
        LOGIC_BY_FU vld;
    } regs;
    typedef struct packed {
        DATA src1;
        DATA src2;
        ID_ALU_VIEW dat;
    } ALU_REGS_EX;
    typedef struct packed {
        DATA src1;
        DATA src2;
        ID_MUL_VIEW dat;
    } MUL_REGS_EX;

    // receive/decode operands from PRF
    ALU_OPS alu_ops, alu_ops_n;
    MUL_OPS mul_ops, mul_ops_n;

    logic [`NUM_FU_ALU-1:0]     alu_ex_rdy;
    logic [`NUM_FU_MULT-1:0]    mul_ex_rdy;
    always_comb begin
        alu_ops_n = '0;
        foreach(alu_in2ops_en[i]) begin
            if(!alu_in2ops_en[i]) 
                continue;
            alu_ops_n.rs1[i] = prf_in.s_v1s.alu[i];
            alu_ops_n.rs2[i] = prf_in.s_v2s.alu[i];

            // ALU opA mux
            case (ins.dat.alu[i].opa_select)
                OPA_IS_RS1:  alu_ops_n.opa[i] = prf_in.s_v1s.alu[i];
                OPA_IS_NPC:  alu_ops_n.opa[i] = ins.dat.alu[i].NPC;
                OPA_IS_PC:   alu_ops_n.opa[i] = ins.dat.alu[i].PC;
                OPA_IS_ZERO: alu_ops_n.opa[i] = 0;
                default:     alu_ops_n.opa[i]= 32'hdeadface; // dead face
            endcase

            // ALU opB mux
            case (ins.dat.alu[i].opb_select)
                OPB_IS_RS2:   alu_ops_n.opb[i] =  prf_in.s_v2s.alu[i];
                OPB_IS_I_IMM: alu_ops_n.opb[i] = `RV32_signext_Iimm(ins.dat.alu[i].inst);
                OPB_IS_S_IMM: alu_ops_n.opb[i] = `RV32_signext_Simm(ins.dat.alu[i].inst);
                OPB_IS_B_IMM: alu_ops_n.opb[i] = `RV32_signext_Bimm(ins.dat.alu[i].inst);
                OPB_IS_U_IMM: alu_ops_n.opb[i] = `RV32_signext_Uimm(ins.dat.alu[i].inst);
                OPB_IS_J_IMM: alu_ops_n.opb[i] = `RV32_signext_Jimm(ins.dat.alu[i].inst);
                default:      alu_ops_n.opb[i] = 32'hfacefeed; // face feed
            endcase

            alu_ops_n.bsy[i]         = ins.vld.alu[i] | (alu_ops.bsy & ~alu_ex_rdy);
            alu_ops_n.alu_func[i]    = ins.dat.alu[i].alu_func;
            alu_ops_n.branch_func[i] = ins.dat.alu[i].inst.b.funct3;
            alu_ops_n.t[i]           = ins.dat.alu[i].t;
            alu_ops_n.rob_idx[i]     = ins.dat.alu[i].rob_idx;
            alu_ops_n.btq_idx[i]     = ins.dat.alu[i].btq_idx;
            alu_ops_n.cond_branch[i]        = ins.dat.alu[i].cond_branch;
            alu_ops_n.uncond_branch[i]      = ins.dat.alu[i].uncond_branch;
        end

        mul_ops_n = '0;
        foreach (mul_in2ops_en[i]) begin
            if (!mul_in2ops_en[i])
                continue;
            mul_ops_n.bsy[i] = ins.vld.mul[i] | (mul_ops.bsy & ~mul_ex_rdy);
            mul_ops_n.rs1[i] = prf_in.s_v1s.mul[i];
            mul_ops_n.rs2[i] = prf_in.s_v2s.mul[i];
            mul_ops_n.func[i] = ins.dat.mul[i].func;
            mul_ops_n.dst[i] = '{
                rob_idx : ins.dat.mul[i].rob_idx,
                tag     : ins.dat.mul[i].t
            };
        end
    end


    // structure results into generic cdb candidates array
    LOGIC_BY_FU vld;

    CPL_CAND_BY_FU cands;
    CPL_CAND [`NUM_FU_TOTAL-1:0] cands_flat;
    assign cands_flat = cands;

    logic [`N-1:0][`NUM_FU_TOTAL-1:0] cdb2fu_gbus;
    LOGIC_BY_FU cpl_gnt;

    logic [`NUM_FU_ALU-1:0] alu_ops2ex_en;
    assign alu_ops2ex_en = alu_ops.bsy & alu_ex_rdy;
    alu_ex alu_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .en     (alu_ops2ex_en),
        .ops    (alu_ops),
        .ex_rdy (alu_ex_rdy),

        .vld    (vld.alu),
        .cands  (cands.alu),
        .cpl_gnt(cpl_gnt.alu)
    );

    logic [`NUM_FU_MULT-1:0] mul_ops2ex_en;
    assign mul_ops2ex_en = mul_ops.bsy & mul_ex_rdy;
    mul_ex mul_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .en     (mul_ops2ex_en),
        .ops    (mul_ops),
        .ex_rdy (mul_ex_rdy),

        .vld    (vld.mul),
        .cands  (cands.mul),
        .cpl_gnt(cpl_gnt.mul)
    );

    psel_gen #(
        .WIDTH(`NUM_FU_TOTAL),
        .REQS(`N)
    ) sel_cpl (
        .req(vld),      // flatten (alu + mul bits) => single [NUM_FU_TOTAL-1:0] bus
        .gnt(cpl_gnt),  // flatten => single bus
        .gnt_bus(cdb2fu_gbus)
    );

    execute2complete c_out_n;
    always_comb begin
        alu_ops_rdy = ~alu_ops.bsy | alu_ex_rdy;
        mul_ops_rdy = ~mul_ops.bsy | mul_ex_rdy;

        rs_out = '{
            fu_rdy_alu      : ins.rdy.alu,
            fu_rdy_mult     : ins.rdy.mul,
            fu_rdy_load     : '0,
            fu_rdy_store    : '0
        };

        c_out_n = '0;
        foreach (cdb2fu_gbus[c, f]) begin
            if (cdb2fu_gbus[c][f]) begin
                c_out_n.c_en[c]       |= 1;
                c_out_n.c_ts[c]       |= cands_flat[f].t;
                c_out_n.c_rob_idxs[c] |= cands_flat[f].rob_idx;
                c_out_n.c_data[c]     |= cands_flat[f].data;
                // TODO: fill these
                c_out_n.btq_idxs[c]   |= cands_flat[f].btq_idx;
                c_out_n.is_branch[c]  |= cands_flat[f].is_brch;
                c_out_n.take[c]       |= cands_flat[f].take;
            end
        end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            alu_ops     <= '0;
            mul_ops     <= '0;
            c_out       <= '0;
        end else begin
            alu_ops     <= alu_ops_n;
            mul_ops     <= mul_ops_n;
            /*
            We buffer c_out for 1 cycle to break the comb. chain...
            cpl_buf.used_scnt(vld) -> psel_gen(vld) -> cpl_buf.rd_en_cnt(cpl_gnt)
            -> cpl_buf.rd_data(cands) -> c_out $#BREAK HERE#$ -> RS issue
            -> FU sbuf.wr_data()

            TODO: Buffering c_out for 1 cycle feels a little questionable.
            Are you sure you're not adding an unnecessary cycle of latency for
            free_list and rob who practically already wait for 1 cycle because
            they have INTR_FWD disabled? Can you simply reenable INTR_FWD for
            them with minimal latency cost?
            */
            c_out       <= c_out_n;

        end
    end

    `ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | >> EXECUTE", $time);

            for (int i = 0; i < `NUM_FU_ALU; ++i) begin
                $display("alu_ins[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, btq_idx: %2d, inst: 0x%x, PC: 0x%x, NPC: 0x%x, cond_branch: %b, uncond_branch: %b",
                    i,
                    ins.rdy.alu[i],
                    ins.vld.alu[i],
                    ins.dat.alu[i].t,
                    ins.dat.alu[i].t1,
                    ins.dat.alu[i].t2,
                    ins.dat.alu[i].rob_idx,
                    ins.dat.alu[i].btq_idx,
                    ins.dat.alu[i].inst,
                    ins.dat.alu[i].PC,
                    ins.dat.alu[i].NPC,
                    ins.dat.alu[i].cond_branch,
                    ins.dat.alu[i].uncond_branch
                );
            end

            for (int i = 0; i < `NUM_FU_MULT; ++i) begin
                $display("mul_ins[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, func: 0x%x",
                    i,
                    ins.rdy.mul[i],
                    ins.vld.mul[i],
                    ins.dat.mul[i].t,
                    ins.dat.mul[i].t1,
                    ins.dat.mul[i].t2,
                    ins.dat.mul[i].rob_idx,
                    ins.dat.mul[i].func
                );
            end

            for (int i = 0; i < `NUM_FU_ALU; ++i) begin
                $display("alu_ops[%0d]: bsy: %b, opa: 0x%x, opb: 0x%x, alu_func: %b, branch_func: %b, cond_branch: %b, uncond_branch: %b, t: %2d, rob_idx: %2d, btq_idx: %2d",
                    i,
                    alu_ops.bsy[i],
                    alu_ops.opa[i],
                    alu_ops.opb[i],
                    alu_ops.alu_func[i],
                    alu_ops.branch_func[i],
                    alu_ops.cond_branch[i],
                    alu_ops.uncond_branch[i],
                    alu_ops.t[i],
                    alu_ops.rob_idx[i],
                    alu_ops.btq_idx[i]
                );
            end

            for (int i = 0; i < `NUM_FU_MULT; ++i) begin
                $display("mul_ops[%0d]: bsy: %b, rs1: 0x%x, rs2: 0x%x, func: %b, t: %2d, rob_idx: %2d",
                    i,
                    mul_ops.bsy[i],
                    mul_ops.rs1[i],
                    mul_ops.rs2[i],
                    mul_ops.func[i],
                    mul_ops.dst[i].tag,
                    mul_ops.dst[i].rob_idx
                );
            end

            $display("c_out: rdy_alu: %b  rdy_mult: %b  rdy_store: %b  rdy_load: %b  cpl_gnt: %b",
                rs_out.fu_rdy_alu,
                rs_out.fu_rdy_mult,
                rs_out.fu_rdy_store,
                rs_out.fu_rdy_load,
                cpl_gnt
            );

            for (int i = 0; i < `N; ++i) begin
                $display("c_out[%0d]: c_en: %b, is_branch: %b, c_ts: %2d, c_rob_idxs: %2d, c_data: %x, btq_idxs: %d, take: %b",
                    i,
                    c_out.c_en[i],
                    c_out.is_branch[i],
                    c_out.c_ts[i],
                    c_out.c_rob_idxs[i],
                    c_out.c_data[i],
                    c_out.btq_idxs[i],
                    c_out.take[i]
                );
            end


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
    `endif // DEBUG

endmodule // stage_ex
