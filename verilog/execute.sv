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
        logic       [`NUM_FU_ALU-1:0]       bsy; // unused; same as en
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
    /*
    credit[i] = num available slots in fifo[i]
              = buf_sz - (num in-flight through FU[i] + num waiting in fifo[i])
    */
    localparam buf_sz = 4;
    logic [`NUM_FU_ALU-1:0][$clog2(buf_sz):0] credits;

    // execute
    generate
        CPL_CAND    [`NUM_FU_ALU-1:0] tmp_data;
        DATA        [`NUM_FU_ALU-1:0] tmp_res;
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            alu alu_0 ( 
                // Inputs
                .opa        (ops.opa[i]),
                .opb        (ops.opb[i]),
                .alu_func   (ops.alu_func[i]),
                .branch_func(ops.branch_func[i]), // Which branch condition to check

                .take(), // True/False condition result (will return FALSE if branch is low)
                .result(tmp_res[i]) // will return 32'hfacebeec if branch is high (Sentinel, hopefully none of our alu computations result in that value)
            );

            assign tmp_data[i] = '{
                t       : ops.t[i],
                rob_idx : ops.rob_idx[i],
                data    : tmp_res[i]
            };

            // <FU>_outs: where executed insns wait until completion
            fifo #(
                .INSTANCE_ID(10+i),
                .DEPTH(buf_sz),
                .WIDTH($bits(CPL_CAND)),
                .NUM_RPORTS(1),
                .NUM_WPORTS(1),
                .ENABLE_INTR_FWD(`FALSE)
            ) cpl_buf (
                .clock      (clock),
                .reset      (reset),
                .wr_en_cnt  (en[i]),
                .wr_data    (tmp_data[i]),
                .rd_en_cnt  (cpl_gnt[i]),
                .rd_data    (cands[i]),

                .free_scnt  (),
                .used_scnt  (vld[i])
            );
        end
    endgenerate

    always_comb begin
        foreach (ex_rdy[i])
            ex_rdy[i] = credits[i] > 0;
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            foreach(credits[i])
                credits[i] <= buf_sz;
        end else begin
            foreach(credits[i])
                credits[i] <= credits[i] - en[i] + cpl_gnt[i];
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
        logic     [`NUM_FU_MULT-1:0]    bsy; // unused; same as en
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
    localparam buf_sz = `MULT_STAGES;
    logic [`NUM_FU_MULT-1:0][$clog2(buf_sz):0] credits;

    // execute
    generate
        logic       [`NUM_FU_MULT-1:0] tmp_done;
        DATA        [`NUM_FU_MULT-1:0] tmp_res;
        DST         [`NUM_FU_MULT-1:0] tmp_dst;
        CPL_CAND    [`NUM_FU_MULT-1:0] tmp_data;
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mults
            mult mult_0 ( 
                .clock  (clock),
                .reset  (reset),
                .flush  (flush),
                .start  (en[i]),
                .dst_in (ops.dst[i]),
                .rs1    (ops.rs1[i]),
                .rs2    (ops.rs2[i]),
                .func   (ops.func[i]),

                // Output
                .dst_out(tmp_dst[i]),
                .result (tmp_res[i]),
                .done   (tmp_done[i])
            );

            assign tmp_data[i] = '{
                t       : tmp_dst[i].tag,
                rob_idx : tmp_dst[i].rob_idx,
                data    : tmp_res[i]
            };

            // <FU>_outs: where executed insns wait until completion
            fifo #(
                .INSTANCE_ID(20+i),
                .DEPTH(buf_sz),
                .WIDTH($bits(CPL_CAND)),
                .NUM_RPORTS(1),
                .NUM_WPORTS(1),
                .ENABLE_INTR_FWD(`FALSE)
            ) cpl_buf (
                .clock      (clock),
                .reset      (reset),
                .wr_en_cnt  (tmp_done[i]),
                .wr_data    (tmp_data[i]),
                .rd_en_cnt  (cpl_gnt[i]),
                .rd_data    (cands[i]),

                .free_scnt  (),
                .used_scnt  (vld[i])
            );
           
        end
    endgenerate

    always_comb begin
        foreach (ex_rdy[i])
            ex_rdy[i] = credits[i] > 0;
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            foreach(credits[i])
                credits[i] <= buf_sz;
        end else begin
            foreach(credits[i])
                credits[i] <= credits[i] - en[i] + cpl_gnt[i];
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

                inst    : rs_in.fu_dat_alu[i].inst,
                PC      : rs_in.fu_dat_alu[i].PC,
                NPC     : rs_in.fu_dat_alu[i].NPC,

                opa_select  : rs_in.fu_dat_alu[i].opa_select,
                opb_select  : rs_in.fu_dat_alu[i].opb_select,
                alu_func    : rs_in.fu_dat_alu[i].alu_func,
                cond_branch : rs_in.fu_dat_alu[i].cond_branch,
                uncond_branch : rs_in.fu_dat_alu[i].uncond_branch
            };
            fifo #(
                .DEPTH(2),
                .WIDTH($bits(ID_ALU_VIEW)),
                .NUM_RPORTS(1),
                .NUM_WPORTS(1),
                .ENABLE_INTR_FWD(`FALSE)
            ) s_buf (
                .clock      (clock),
                .reset      (reset),
                .wr_en_cnt  (rs_in.fu_vld_alu[i]),
                .wr_data    (tmp_alu_el[i]),
                .rd_en_cnt  (alu_in2ops_en[i]),
                .rd_data    (ins.dat.alu[i]),

                .free_scnt  (ins.rdy.alu[i]),
                .used_scnt  (ins.vld.alu[i])
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
            fifo #(
                .DEPTH(2),
                .WIDTH($bits(ID_MUL_VIEW)),
                .NUM_RPORTS(1),
                .NUM_WPORTS(1),
                .ENABLE_INTR_FWD(`FALSE)
            ) s_buf (
                .clock      (clock),
                .reset      (reset),
                .wr_en_cnt  (rs_in.fu_vld_mult[i]),
                .wr_data    (tmp_mul_el[i]),
                .rd_en_cnt  (mul_in2ops_en[i]),
                .rd_data    (ins.dat.mul[i]),

                .free_scnt  (ins.rdy.mul[i]),
                .used_scnt  (ins.vld.mul[i])
            );
        end
    endgenerate

    // request operands from PRF (separate stage)
    always_comb begin
        prf_out = '0;
        foreach (alu_in2ops_en[i]) begin
            if (!alu_in2ops_en[i])
                continue;
            prf_out.s_en1s.alu[i]   = ins.dat.alu[i].opa_select == OPA_IS_RS1;
            prf_out.s_en2s.alu[i]   = ins.dat.alu[i].opb_select == OPB_IS_RS2;
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

    // receive/decode operands from PRF
    struct packed {
        logic       [`NUM_FU_ALU-1:0]       bsy;
        DATA        [`NUM_FU_ALU-1:0]       opa, opb;
        ALU_FUNC    [`NUM_FU_ALU-1:0]       alu_func;
        logic       [`NUM_FU_ALU-1:0][2:0]  branch_func; // Which branch condition to check
        // 
        PHYS_REG_IDX [`NUM_FU_ALU-1:0]      t;
        ROB_IDX      [`NUM_FU_ALU-1:0]      rob_idx;
    } alu_ops, alu_ops_n;
    struct packed {
        logic       [`NUM_FU_MULT-1:0]      bsy;
        DATA        [`NUM_FU_MULT-1:0]      rs1, rs2;
        MULT_FUNC   [`NUM_FU_MULT-1:0]      func;
        DST         [`NUM_FU_MULT-1:0]      dst;
    } mul_ops, mul_ops_n;

    logic [`NUM_FU_ALU-1:0]     alu_ex_rdy;
    logic [`NUM_FU_MULT-1:0]    mul_ex_rdy;
    always_comb begin
        alu_ops_n = '0;
        foreach(alu_in2ops_en[i]) begin
            if(!alu_in2ops_en[i]) 
                continue;

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

            $display("  %3d | >> EXECUTE", $time);
            $display("alu_ins: bsy[%b, %b], mul_ins: bsy[%b, %b]",
                ins.rdy.alu[0],
                ins.rdy.alu[1],
                ins.rdy.mul[0],
                ins.rdy.mul[1]
            );
            $display("alu_ops: [%b {opa: %x opb: %x}, %b {opa: %x opb: %x}]",
                alu_ops.bsy[0],
                alu_ops.opa[0],
                alu_ops.opb[0],
                alu_ops.bsy[1],
                alu_ops.opa[1],
                alu_ops.opb[1]
            );
            $display("mul_ops: [%b {rs1: %x rs2: %x dst: %0d}, %b {rs1: %x rs2: %x dst: %0d}]",
                mul_ops.bsy[0],
                mul_ops.rs1[0],
                mul_ops.rs2[0],
                mul_ops.dst[0].tag,
                mul_ops.bsy[1],
                mul_ops.rs1[1],
                mul_ops.rs2[1],
                mul_ops.dst[1].tag
            );
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
