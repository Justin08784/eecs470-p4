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
`include "execute.svh"
`include "ISA.svh"

/*
Flow chart
[Reservation Station] 
     ↓
[Staging FIFO (s_buf)]  ← just buffers instruction for 1 cycle
     ↓
[regs register (r_buf)]  ← PRF values fetched here
     ↓
[Functional Unit (ALU, MUL, LOD, or STR)]
     ↓
[CDB Output Reg (c_out)] ← selected for writeback this cycle

CDB arbitration:
- For 1-cycle op, arbitration occurs in [RS] -> [s_buf]
- For ≥ 4 cycle ops, it occurs in [FU]
- For < 4 cycle ops, it occurs *before* [FU] (but we dont support any
ops in this category, so we wouldn't know)
*/

// ALU: computes the result of FUNC applied with operands A and B
// This module is purely combinational
module alu (
    input DATA      opa,
    input DATA      opb,
    input ALU_FUNC  alu_func,

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
endmodule // alu


module alu_ex(
    /* FRONTEND */
    input   logic [NUM_FU_ALU-1:0]      i_vld,
    input   BMASK [NUM_FU_ALU-1:0]      i_msk,
    input   ALU_REGS [NUM_FU_ALU-1:0]   i_regs,
        // insn metadata/operands

    /* BACKEND */
    output logic    [NUM_FU_ALU-1:0]    o_cands_vld,
    output BMASK    [NUM_FU_ALU-1:0]    o_cands_msk,
    output CPL_CAND [NUM_FU_ALU-1:0]    o_cands
);
    // execute
    assign o_cands_vld = i_vld;
    assign o_cands_msk = i_msk;
    generate
        DATA        [NUM_FU_ALU-1:0] tmp_res;
        for (genvar i = 0; i < NUM_FU_ALU; ++i) begin : gen_alus
            alu alu_0 ( 
                // Inputs
                .opa        (i_regs[i].opa),
                .opb        (i_regs[i].opb),
                .alu_func   (i_regs[i].alu_func),

                // Output (directly to cdat_out)
                .result     (tmp_res[i])
            );

            assign o_cands[i] = '{
                t       : i_regs[i].t,
                rob_idx : i_regs[i].rob_idx,
                data    : tmp_res[i]
            };
        end
    endgenerate
endmodule

module str_ex (
    /* FRONTEND */
    input   logic [NUM_FU_STR-1:0]      i_vld,
    input   BMASK [NUM_FU_STR-1:0]      i_msk,
    input   STR_REGS [NUM_FU_STR-1:0]   i_regs,
        // insn metadata/operands

    /* BACKEND */
    output execute2complete_str         cstr_out
);
    assign cstr_out.en = i_vld;
    assign cstr_out.msk= i_msk;
    for (genvar i = 0; i < NUM_FU_STR; ++i) begin
        assign cstr_out.dat[i] = '{
            rob_idx : i_regs[i].dat.rob_idx,
            sq_idx  : i_regs[i].dat.sq_idx,
            dst     : i_regs[i].rs1 + i_regs[i].dat.opb,
            size    : i_regs[i].dat.mem_size,
            dat     : i_regs[i].rs2
        };
    end
endmodule

module mul_ex(
    input clock,
    input reset,
    input flush,
    input BMASK clmsk,

    /* FRONTEND */
    output logic    [NUM_FU_MUL-1:0]  i_rdy,
        // ready to accept from regs.o_dat.mul?
    input  logic    [NUM_FU_MUL-1:0]  i_vld,
        // insns to accept from regs.o_dat.mul
    input  MUL_REGS [NUM_FU_MUL-1:0]  i_regs,
        // insn metadata/operands
    input  BMASK    [NUM_FU_MUL-1:0]  i_msk,

    /* Early CDB arbitration */
    output logic [NUM_FU_MUL-1:0]       cdb_req,
    output BMASK [NUM_FU_MUL-1:0]       ctag_msks,
    output PHYS_REG_IDX [NUM_FU_MUL-1:0]ctag_ts,
    input  logic [NUM_FU_MUL-1:0]       cdb_gnt,

    /* BACKEND */
    output logic    [NUM_FU_MUL-1:0]  o_cands_vld,
    output BMASK    [NUM_FU_MUL-1:0]  o_cands_msk,
    output CPL_CAND [NUM_FU_MUL-1:0]  o_cands
);
    // execute
    generate
        DATA        [NUM_FU_MUL-1:0] tmp_res;
        PHYS_REG_IDX[NUM_FU_MUL-1:0] tmp_t;
        ROB_IDX     [NUM_FU_MUL-1:0] tmp_rob_idx;

        for (genvar i = 0; i < NUM_FU_MUL; ++i) begin : gen_mults
            mult #(
                .ID(i)
            ) mult_0 ( 
                .clock,
                .reset,
                .flush,
                .clmsk,

                .i_vld  (i_vld[i]),
                .i_rdy  (i_rdy[i]),
                .rs1    (i_regs[i].rs1),
                .rs2    (i_regs[i].rs2),
                .func   (i_regs[i].func),
                .i_msk  (i_msk[i]),
                .i_t    (i_regs[i].t),
                .i_rob_idx(i_regs[i].rob_idx),

                .cdb_req(cdb_req[i]),
                .ctag_msk(ctag_msks[i]),
                .ctag_t (ctag_ts[i]),
                .cdb_gnt(cdb_gnt[i]),

                // Output (directly to cdat_out)
                .o_vld  (o_cands_vld[i]),
                .o_msk  (o_cands_msk[i]),
                .o_t    (tmp_t[i]),
                .o_rob_idx(tmp_rob_idx[i]),
                .result (tmp_res[i])
            );

            assign o_cands[i] = '{
                t       : tmp_t[i],
                rob_idx : tmp_rob_idx[i],
                data    : tmp_res[i]
            };
        end
    endgenerate
endmodule

module bru (
    input DATA      opa,
    input DATA      opb,
    input DATA      rs1,
    input DATA      rs2,
    input [2:0]     branch_func, // Which branch condition to check

    output logic    take, // True/False condition result
    output DATA     result
);

    assign result = opa + opb;

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

endmodule // bru

module bru_ex(
    /* FRONTEND */
    input  logic        i_vld,
    input  BMASK        i_msk,
    input  BRU_REGS     i_reg,
    input  btq2execute  btq_in,
        // insn metadata/operands

    /* BACKEND */
    output execute2complete_bru cbru_out,
    output logic                o_cand_vld,
    output BMASK                o_cand_msk,
    output CPL_CAND             o_cand
);
    initial begin
        assert (NUM_FU_BRU == 1) else $fatal("bru_ex: assumes 1 BRU");
    end

    ADDR pc_addr, npc_addr;
    assign pc_addr  = w2addr(i_reg.PC);
    assign npc_addr = w2addr(i_reg.PC + `UCAST_FIT(1));

    DATA opa, opb;
    always_comb begin
        // BRU opA mux
        case (i_reg.opa_select)
            OPA_IS_PC:  opa = pc_addr;
            OPA_IS_RS1: opa = i_reg.rs1;
            default:    opa = 32'hdeadface; // dead face
        endcase

        // BRU opB mux
        opb = i_reg.opb_is_rs2
            ? i_reg.rs2
            : i_reg.imm32b;
    end

    // execute
    DATA    tmp_res;
    logic   cond_take, tmp_take;
    bru bru_0 ( 
        // Inputs
        .opa        (opa),
        .opb        (opb),
        .rs1        (i_reg.rs1),
        .rs2        (i_reg.rs2),
        .branch_func(i_reg.func),

        // Output (directly to cdat_out)
        .take       (cond_take),
        .result     (tmp_res)
    );

    assign tmp_take = !i_reg.cond_branch || cond_take;

    assign o_cand_vld = i_vld;
    assign o_cand_msk = i_msk;
    assign o_cand = '{
        t       : i_reg.t,
        rob_idx : i_reg.rob_idx,
        data    : tmp_take ? npc_addr : tmp_res
    };


    logic pred;
    logic take;
    logic corr_tgt;

`ifdef DEBUG
    BRANCH_RESO_CODE reso;
    assign reso = '{
        pred    :pred,
        take    :take,
        corr_tgt:corr_tgt
    };
`endif

    /*
    Rob completion paths (i.e. how do we mark our rob entry has complete?):
    1. Dest-less (t == `ZERO_PHYS_REG) : via cbru_out slot
    2. Has dst   (t != `ZERO_PHYS_REG) : via cbru_out slot AND a cdat_out (cdb) slot
        - In that cycle, there will be two identical completions to the ROB, which is inelegant but not incorrect.
    */
    logic mispred;
    WADDR flush_fb_base;
    logic [3:0] flush_fb_off;
    BMASK clmsk;
    assign cbru_out = '{
        en      : i_vld,
        take    : tmp_take,
        tgt     : addr2w(tmp_res),
        rob_idx : i_reg.rob_idx,
        btq_idx : i_reg.btq_idx,

`ifdef DEBUG
        reso    : reso,
`endif
        clmsk   : i_vld ? i_reg.b1hot : '0,
        flush           : i_vld & mispred,
        flush_ghr_base  : btq_in.ghr_base,
        flush_fb_base   : flush_fb_base,
        flush_fb_off    : flush_fb_off
    };


    always_comb begin
        WADDR npc;
        WADDR tgt;

        pred     = btq_in.pred;
        take     = cbru_out.take;
        corr_tgt = btq_in.pred_tgt == cbru_out.tgt;
        npc      = i_reg.PC + `UCAST_FIT(1);
        tgt      = cbru_out.tgt;

        mispred = 0;
        flush_fb_base   = '0;
        flush_fb_off    = '0;


        unique casez ({pred, take, corr_tgt})
        3'b010,
        3'b011,
        3'b110: begin
            mispred = 1;

            flush_fb_base   = tgt;
            flush_fb_off    = '0;
        end

        3'b100,
        3'b101: begin
            mispred = 1;

            if (&btq_in.fb_off  // i.e. btq_in.fb_off == 15. npc would be in next fetch block
            || btq_in.is_tail
            ) begin
                flush_fb_off    = '0;
                flush_fb_base   = npc;

            end else begin
                flush_fb_base   = i_reg.PC - btq_in.fb_off;
                flush_fb_off    = btq_in.fb_off + `UCAST_FIT(1);

            end
        end

        default:;

        endcase
    end

endmodule

// module execute (
module stage_ex_p4 (
    input   clock,
    input   reset,

    /* NOTE: no flush/clmsk inputs–– they are generated here! */

    input   rs2execute rs_in,
    output  execute2rs rs_out,

    input   dcache2ld   dcache_in,
    output  ld2dcache   dcache_out,

    input   prf2execute prf_in,
    output  execute2prf prf_out,

    input   btq2execute btq_in,
    output  execute2btq btq_out,

    output  execute2complete_bru cbru_out,
    output  execute2complete_tag ctag_out,
    output  execute2complete_dat cdat_out,
    output  execute2complete_str cstr_out

);
    // local convenience variables
    logic flush;
    BMASK clmsk;
    assign flush = cbru_out.flush;
    assign clmsk = cbru_out.clmsk;

    /* >> ======== STAGE 1: Issue Staging ======== >> */
    // (where just-issued insns wait for 1 cycle)
    struct packed {
        `BY_FU(logic)   i_rdy;
        `BY_FU(logic)   o_vld;

        `BY_FU(BMASK)   o_msk;

        struct packed {
            ID_ALU_VIEW [NUM_FU_ALU-1:0]   alu;
            ID_MUL_VIEW [NUM_FU_MUL-1:0]   mul;
            ID_LOD_VIEW [NUM_FU_LOD-1:0]   lod;
            ID_STR_VIEW [NUM_FU_STR-1:0]   str;
            ID_BRU_VIEW [NUM_FU_BRU-1:0]   bru;
        } i_dat, o_dat;
    } iss;

    struct packed {
        `BY_FU(logic) i_rdy;
        `BY_FU(logic) o_vld;

        `BY_FU(BMASK) o_msk;

        struct packed {
            ALU_REGS [NUM_FU_ALU-1:0]  alu;
            MUL_REGS [NUM_FU_MUL-1:0]  mul;
            LOD_REGS [NUM_FU_LOD-1:0]  lod;
            STR_REGS [NUM_FU_STR-1:0]  str;
            BRU_REGS [NUM_FU_BRU-1:0]  bru;
        } i_dat, o_dat;
    } regs;
    
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
        for (genvar i = 0; i < NUM_FU_ALU; ++i) begin : gen_alu_sbufs
            assign iss.i_dat.alu[i] = '{
                bytag   : rs_in.bytag_alu[i],

                t       : rs_in.fu_dat_alu[i].t,
                t1      : rs_in.fu_dat_alu[i].t1,
                t2      : rs_in.fu_dat_alu[i].t2,
                rob_idx : rs_in.fu_dat_alu[i].rob_idx,

                inst    : rs_in.fu_dat_alu[i].inst,
                PC      : rs_in.fu_dat_alu[i].PC,

                opa_select  : rs_in.fu_dat_alu[i].opa_select,
                opb_select  : rs_in.fu_dat_alu[i].opb_select,
                alu_func    : rs_in.fu_dat_alu[i].alu_func
            };

            assign iss.i_rdy.alu[i] = 1;
            flop #(
                .WIDTH($bits(ID_ALU_VIEW))
            ) sbuf_alu (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld (rs_in.fu_en_alu[i]),
                .i_msk (rs_in.fu_dat_alu[i].bmask),
                .i_dat (iss.i_dat.alu[i]),

                .o_vld (iss.o_vld.alu[i]),
                .o_msk (iss.o_msk.alu[i]),
                .o_dat (iss.o_dat.alu[i])
            );
        end
        
        for (genvar i = 0; i < NUM_FU_MUL; ++i) begin : gen_mul_sbufs
            assign iss.i_dat.mul[i] = '{
                t       : rs_in.fu_dat_mul[i].t,
                t1      : rs_in.fu_dat_mul[i].t1,
                t2      : rs_in.fu_dat_mul[i].t2,
                rob_idx : rs_in.fu_dat_mul[i].rob_idx,
                func    : rs_in.fu_dat_mul[i].func
            };

            ppln_skid #(
                .WIDTH($bits(ID_MUL_VIEW))
            ) sbuf_mul (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld (rs_in.fu_en_mul[i]),
                .i_rdy (iss.i_rdy.mul[i]),
                .i_msk (rs_in.fu_dat_mul[i].bmask),
                .i_dat (iss.i_dat.mul[i]),

                .o_vld (iss.o_vld.mul[i]),
                .o_rdy (regs.i_rdy.mul[i]),
                .o_msk (iss.o_msk.mul[i]),
                .o_dat (iss.o_dat.mul[i])
            );
        end

        for (genvar i = 0; i < NUM_FU_LOD; ++i) begin : gen_lod_sbufs
            INST tmp_inst;
            always_comb begin
                tmp_inst        = '0;
                tmp_inst.i.imm  = rs_in.fu_dat_lod[i].imm;
            end

            assign iss.i_dat.lod[i] = '{
                t           : rs_in.fu_dat_lod[i].t,
                t1          : rs_in.fu_dat_lod[i].t1,
                opb         : `RV32_signext_Iimm(tmp_inst),

                // >> FIXME
                // sq_idx      : '0,
                // lq_idx      : '0,
                // << FIXME

                rob_idx     : rs_in.fu_dat_lod[i].rob_idx,
                mem_size    : MEM_SIZE'(rs_in.fu_dat_lod[i].funct3[1:0]),
                rd_unsigned : rs_in.fu_dat_lod[i].funct3[2]
            };

            ppln_skid #(
                .WIDTH($bits(ID_LOD_VIEW))
            ) sbuf_lod (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld (rs_in.fu_en_lod[i]),
                .i_rdy (iss.i_rdy.lod[i]),
                .i_msk (rs_in.fu_dat_lod[i].bmask),
                .i_dat (iss.i_dat.lod[i]),

                .o_vld (iss.o_vld.lod[i]),
                .o_rdy (regs.i_rdy.lod[i]),
                .o_msk (iss.o_msk.lod[i]),
                .o_dat (iss.o_dat.lod[i])
            );
        end

        for (genvar i = 0; i < NUM_FU_STR; ++i) begin : gen_str_sbufs
            INST tmp_inst;
            always_comb begin
                tmp_inst        = '0;
                tmp_inst.s.off  = rs_in.fu_dat_str[i].off_11_5;
                tmp_inst.s.set  = rs_in.fu_dat_str[i].off_4_0;
            end

            assign iss.i_dat.str[i] = '{
                bytag   : rs_in.bytag_str[i],

                t1      : rs_in.fu_dat_str[i].t1,
                t2      : rs_in.fu_dat_str[i].t2,
                opb     : `RV32_signext_Simm(tmp_inst),

                sq_idx  : rs_in.fu_dat_str[i].sq_idx,
                rob_idx : rs_in.fu_dat_str[i].rob_idx,
                mem_size: MEM_SIZE'(rs_in.fu_dat_str[i].funct3[1:0])
            };

            assign iss.i_rdy.str[i] = 1'b1;
            flop #(
                .WIDTH($bits(ID_STR_VIEW))
            ) sbuf_str (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld (rs_in.fu_en_str[i]),
                .i_msk (rs_in.fu_dat_str[i].bmask),
                .i_dat (iss.i_dat.str[i]),

                .o_vld (iss.o_vld.str[i]),
                .o_msk (iss.o_msk.str[i]),
                .o_dat (iss.o_dat.str[i])
            );
        end

        for (genvar i = 0; i < NUM_FU_BRU; ++i) begin : gen_bru_sbufs
            assign iss.i_dat.bru[i] = '{
                bytag   : rs_in.bytag_bru[i],
                b1hot   : rs_in.fu_dat_bru[i].b1hot,

                has_dst : rs_in.fu_dat_bru[i].has_dst,
                t       : rs_in.fu_dat_bru[i].t,
                t1      : rs_in.fu_dat_bru[i].t1,
                t2      : rs_in.fu_dat_bru[i].t2,
                rob_idx : rs_in.fu_dat_bru[i].rob_idx,
                btq_idx : rs_in.fu_dat_bru[i].btq_idx,

                inst    : rs_in.fu_dat_bru[i].inst,
                PC      : rs_in.fu_dat_bru[i].PC,

                opa_select  : rs_in.fu_dat_bru[i].opa_select,
                opb_select  : rs_in.fu_dat_bru[i].opb_select,
                cond_branch : rs_in.fu_dat_bru[i].cond_branch
            };

            assign iss.i_rdy.bru[i] = 1;
            flop #(
                .WIDTH($bits(ID_BRU_VIEW))
            ) sbuf_bru (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld (rs_in.fu_en_bru[i]),
                .i_msk (rs_in.fu_dat_bru[i].bmask),
                .i_dat (iss.i_dat.bru[i]),

                .o_vld (iss.o_vld.bru[i]),
                .o_msk (iss.o_msk.bru[i]),
                .o_dat (iss.o_dat.bru[i])
            );
        end
    endgenerate

    /* >> ======== STAGE 2: PRF Read ======== >> */
    // fetch rs1, rs2 from PRF **IF NOT BYPASSING**
    always_comb begin
        prf_out = '0;
        foreach (iss.o_vld.alu[i]) begin
            prf_out.en1s.alu[i]   = iss.o_vld.alu[i];
            prf_out.en2s.alu[i]   = iss.o_vld.alu[i];
            prf_out.t1s.alu[i]    = iss.o_dat.alu[i].t1; 
            prf_out.t2s.alu[i]    = iss.o_dat.alu[i].t2; 
        end
        foreach (iss.o_vld.mul[i]) begin
            prf_out.en1s.mul[i]   = iss.o_vld.mul[i];
            prf_out.en2s.mul[i]   = iss.o_vld.mul[i];
            prf_out.t1s.mul[i]    = iss.o_dat.mul[i].t1; 
            prf_out.t2s.mul[i]    = iss.o_dat.mul[i].t2; 
        end
        foreach (iss.o_vld.lod[i]) begin
            prf_out.en1s.lod[i]   = iss.o_vld.lod[i];
            prf_out.t1s.lod[i]    = iss.o_dat.lod[i].t1; 
        end
        foreach (iss.o_vld.str[i]) begin
            prf_out.en1s.str[i]   = iss.o_vld.str[i];
            prf_out.en2s.str[i]   = iss.o_vld.str[i];
            prf_out.t1s.str[i]    = iss.o_dat.str[i].t1; 
            prf_out.t2s.str[i]    = iss.o_dat.str[i].t2; 
        end
        foreach (iss.o_vld.bru[i]) begin
            prf_out.en1s.bru[i]   = iss.o_vld.bru[i];
            prf_out.en2s.bru[i]   = iss.o_vld.bru[i];
            prf_out.t1s.bru[i]    = iss.o_dat.bru[i].t1; 
            prf_out.t2s.bru[i]    = iss.o_dat.bru[i].t2; 
        end
    end

    struct packed {
        `BY_FU(logic) i_rdy;
    } ex;
    execute2btq btq_out_n;
    always_comb begin
        foreach (iss.o_vld.alu[i]) begin
            DATA imm32a, imm32b;
            logic opa_is_rs1, opb_is_rs2;
            ADDR pc_addr, npc_addr;
            pc_addr  = w2addr(iss.o_dat.alu[i].PC);
            npc_addr = w2addr(iss.o_dat.alu[i].PC + `UCAST_FIT(1));

            opa_is_rs1 = iss.o_dat.alu[i].opa_select == OPA_IS_RS1;
            case (iss.o_dat.alu[i].opa_select)
                OPA_IS_RS1:  imm32a = '0;
                OPA_IS_NPC:  imm32a = npc_addr;
                OPA_IS_PC:   imm32a = pc_addr;
                OPA_IS_ZERO: imm32a = 0;
                default:     imm32a = 32'hdeadface; // dead face
            endcase

            opb_is_rs2 = iss.o_dat.alu[i].opb_select == OPB_IS_RS2;
            case (iss.o_dat.alu[i].opb_select)
                OPB_IS_RS2:   imm32b =  '0;
                OPB_IS_I_IMM: imm32b = `RV32_signext_Iimm(iss.o_dat.alu[i].inst);
                OPB_IS_S_IMM: imm32b = `RV32_signext_Simm(iss.o_dat.alu[i].inst);
                OPB_IS_B_IMM: imm32b = `RV32_signext_Bimm(iss.o_dat.alu[i].inst);
                OPB_IS_U_IMM: imm32b = `RV32_signext_Uimm(iss.o_dat.alu[i].inst);
                OPB_IS_J_IMM: imm32b = `RV32_signext_Jimm(iss.o_dat.alu[i].inst);
                default:      imm32b = 32'hfacefeed; // face feed
            endcase

            regs.i_dat.alu[i] = '{
                bytag : iss.o_dat.alu[i].bytag,

                opa : opa_is_rs1
                    ? prf_in.v1s.alu[i]
                    : imm32a,
                opb : opb_is_rs2
                    ? prf_in.v2s.alu[i]
                    : imm32b,

                opa_is_rs1  : opa_is_rs1,
                opb_is_rs2  : opb_is_rs2,
                alu_func    : iss.o_dat.alu[i].alu_func,

                t           : iss.o_dat.alu[i].t,
                rob_idx     : iss.o_dat.alu[i].rob_idx
            };
        end
        foreach (iss.o_vld.mul[i]) begin
            regs.i_dat.mul[i] = '{
                rs1 : prf_in.v1s.mul[i],
                rs2 : prf_in.v2s.mul[i],
                t1  : iss.o_dat.mul[i].t1,
                t2  : iss.o_dat.mul[i].t2,

                func    : iss.o_dat.mul[i].func,

                t       : iss.o_dat.mul[i].t,
                rob_idx : iss.o_dat.mul[i].rob_idx
            };
        end
        foreach (iss.o_vld.lod[i]) begin
            regs.i_dat.lod[i] = '{
                rs1 : prf_in.v1s.lod[i],
                dat : iss.o_dat.lod[i]
            };
        end
        foreach (iss.o_vld.str[i]) begin
            regs.i_dat.str[i] = '{
                bytag   : iss.o_dat.str[i].bytag,
                rs1 : prf_in.v1s.str[i],
                rs2 : prf_in.v2s.str[i],
                dat : iss.o_dat.str[i]
            };
        end
        foreach (iss.o_vld.bru[i]) begin
            DATA imm32b;
            case (iss.o_dat.bru[i].opb_select)
                OPB_IS_I_IMM: imm32b = `RV32_signext_Iimm(iss.o_dat.bru[i].inst);
                OPB_IS_B_IMM: imm32b = `RV32_signext_Bimm(iss.o_dat.bru[i].inst);
                OPB_IS_J_IMM: imm32b = `RV32_signext_Jimm(iss.o_dat.bru[i].inst);
                default:      imm32b = 32'hfacefeed; // face feed
            endcase

            btq_out_n.btq_ridx[i] = iss.o_dat.bru[i].btq_idx;

            regs.i_dat.bru[i] = '{
                bytag : iss.o_dat.bru[i].bytag,
                b1hot : iss.o_dat.bru[i].b1hot,

                rs1 : prf_in.v1s.bru[i],
                rs2 : prf_in.v2s.bru[i],

                PC          : iss.o_dat.bru[i].PC,
                opa_select  : iss.o_dat.bru[i].opa_select,
                opb_is_rs2  : iss.o_dat.bru[i].opb_select == OPB_IS_RS2,
                imm32b      : imm32b,
                func        : iss.o_dat.bru[i].inst.b.funct3,
                cond_branch : iss.o_dat.bru[i].cond_branch,

                has_dst     : iss.o_dat.bru[i].has_dst,
                t           : iss.o_dat.bru[i].t,
                rob_idx     : iss.o_dat.bru[i].rob_idx,
                btq_idx     : iss.o_dat.bru[i].btq_idx
            };
        end
    end

    generate
        assign regs.i_rdy.alu = '1;
        for (genvar i = 0; i < NUM_FU_ALU; ++i) begin : gen_alu_rbufs
            /* Unlike mul, lod, str, we *shouldn't* need snooping to feed back
            into rbuf (via i_snoop) because we *should* never stall post issue. */
            ALU_REGS raw;
            flop #(
                .WIDTH($bits(ALU_REGS))
            ) rbuf_alu (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld (iss.o_vld.alu[i]),
                .i_msk (iss.o_msk.alu[i]),
                .i_dat (regs.i_dat.alu[i]),

                .o_vld (regs.o_vld.alu[i]),
                .o_msk (regs.o_msk.alu[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.alu[i] = alu_snoop(raw, cdat_out);
        end

        for (genvar i = 0; i < NUM_FU_MUL; ++i) begin : gen_mul_rbufs
            /* Even if we are stalled, we must snoop the CDB to make sure
            we don't miss the 1 cycle bypass window. */
            MUL_REGS raw;
            skid #(
                .ENABLE_SNOOP(`TRUE),
                .WIDTH($bits(MUL_REGS))
            ) rbuf_mul (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_snoop(regs.o_dat.mul[i]),

                .i_vld (iss.o_vld.mul[i]),
                .i_rdy (regs.i_rdy.mul[i]),
                .i_msk (iss.o_msk.mul[i]),
                .i_dat (regs.i_dat.mul[i]),

                .o_vld (regs.o_vld.mul[i]),
                .o_rdy (ex.i_rdy.mul[i]),
                .o_msk (regs.o_msk.mul[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.mul[i] = mul_snoop(raw, cdat_out);
        end

        for (genvar i = 0; i < NUM_FU_LOD; ++i) begin : gen_lod_rbufs
            LOD_REGS raw_tmp, raw_dat;
            ppln_skid #(
                .ENABLE_SNOOP(`TRUE),
                .WIDTH($bits(LOD_REGS))
            ) rbuf_lod (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_snoop_tmp(lod_snoop(raw_tmp, cdat_out)),
                .i_snoop_dat(regs.o_dat.lod[i]),
                .o_tmp      (raw_tmp),

                .i_vld (iss.o_vld.lod[i]),
                .i_rdy (regs.i_rdy.lod[i]),
                .i_msk (iss.o_msk.lod[i]),
                .i_dat (regs.i_dat.lod[i]),

                .o_vld (regs.o_vld.lod[i]),
                .o_rdy (ex.i_rdy.lod[i]),
                .o_msk (regs.o_msk.lod[i]),
                .o_dat (raw_dat)
            );
            assign regs.o_dat.lod[i] = lod_snoop(raw_dat, cdat_out);
        end

        assign regs.i_rdy.str = '1;
        for (genvar i = 0; i < NUM_FU_STR; ++i) begin : gen_str_rbufs
            STR_REGS raw;
            flop #(
                .WIDTH($bits(STR_REGS))
            ) rbuf_str (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld (iss.o_vld.str[i]),
                .i_msk (iss.o_msk.str[i]),
                .i_dat (regs.i_dat.str[i]),

                .o_vld (regs.o_vld.str[i]),
                .o_msk (regs.o_msk.str[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.str[i] = str_snoop(raw, cdat_out);
        end

        assign regs.i_rdy.bru = '1;
        for (genvar i = 0; i < NUM_FU_BRU; ++i) begin : gen_bru_rbufs
            /* Unlike mul, lod, str, we *shouldn't* need snooping to feed back
            into rbuf (via i_snoop) because we *should* never stall post issue. */
            BRU_REGS raw;
            flop #(
                .WIDTH($bits(BRU_REGS))
            ) rbuf_bru (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld (iss.o_vld.bru[i]),
                .i_msk (iss.o_msk.bru[i]),
                .i_dat (regs.i_dat.bru[i]),

                .o_vld (regs.o_vld.bru[i]),
                .o_msk (regs.o_msk.bru[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.bru[i] = bru_snoop(raw, cdat_out);
        end
    endgenerate

    /* >> ======== STAGE ?: (early) CDB arbitration ======== >> */
    // If 1-cycle operation (e.g. ALU), this is before issue staging.
    // Else if a longer-latency insn, this is in the middle of execution.

    `BY_FU(logic)   cands_vld;
    `BY_FU(BMASK)   cands_msk;
    `BY_FU(CPL_CAND)cands;
    logic [NUM_FU_TOTAL-1:0]    cands_flat_vldv;
    CPL_CAND [NUM_FU_TOTAL-1:0] cands_flat;
    assign cands_vld.str    = '0;
    assign cands_msk.str    = '0;
    assign cands.str        = '0; // alu, mul, lod set by respective *_ex's
    assign cands_flat_vldv  = cands_vld;
    assign cands_flat       = cands;

    /*
    Complete grant bus shift register
    */
    logic [1:0][N-1:0][NUM_FU_TOTAL-1:0]  cdb2fu_gbus_shr;
    logic [N-1:0][NUM_FU_TOTAL-1:0]       cdb2fu_gbus;
    `BY_FU(logic) [1:0] cdb_gnt_shr;

    `BY_FU(logic) cdb_req;
    assign cdb_req.alu = rs_in.fu_vld_alu;
    // cdb_req.mul set by mul_ex
    // cdb_req.lod set by lod_ex
    assign cdb_req.str = '0;
        logic [NUM_FU_BRU-1:0] rs_in_fu_has_dst_bru;
        for (genvar f = 0; f < NUM_FU_BRU; ++f)
            assign rs_in_fu_has_dst_bru[f] = rs_in.fu_dat_bru[f].has_dst;
    assign cdb_req.bru = rs_in.fu_vld_bru & rs_in_fu_has_dst_bru; // a dest-less branch does not contend for CDB (it simply uses the FU's cbru_out slot)
    `BY_FU(logic) cdb_gnt;

    psel_gen #(
        .WIDTH(NUM_FU_TOTAL),
        .REQS(N)
    ) cdb_arb (
        .req    (cdb_req),  // flatten (alu + mul bits) => single [NUM_FU_TOTAL-1:0] bus
        .gnt    (cdb_gnt),  // flatten => single bus
        .gnt_bus(cdb2fu_gbus)
    );

    /* >> ======== STAGE 3: Execution ======== >> */
    // Includes operand decode/CDB bypass just before 1st cycle of execution.

    alu_ex alu_ex0 (
        .i_vld      (regs.o_vld.alu),
        .i_msk      (regs.o_msk.alu),
        .i_regs     (regs.o_dat.alu),

        .o_cands_vld(cands_vld.alu),
        .o_cands_msk(cands_msk.alu),
        .o_cands    (cands.alu)
    );

    `BY_FU(BMASK)       ctag_msks;
    `BY_FU(PHYS_REG_IDX)ctag_ts; // FIXME: do we need selective flush this?
    BMASK       [NUM_FU_TOTAL-1:0] ctag_msks_flat;
    PHYS_REG_IDX[NUM_FU_TOTAL-1:0] ctag_ts_flat;

    mul_ex mul_ex0 (
        .clock,
        .reset,
        .flush,
        .clmsk,

        .i_vld      (regs.o_vld.mul),
        .i_msk      (regs.o_msk.mul),
        .i_regs     (regs.o_dat.mul),
        .i_rdy      (ex.i_rdy.mul),

        .cdb_req    (cdb_req.mul),
        .ctag_msks  (ctag_msks.mul),
        .ctag_ts    (ctag_ts.mul),
        .cdb_gnt    (cdb_gnt.mul),

        .o_cands_vld(cands_vld.mul),
        .o_cands_msk(cands_msk.mul),
        .o_cands    (cands.mul)
    );

    lod_ex lod_ex0 (
`ifdef DEBUG
        .print_en   (1'b1),
`endif
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .clmsk      (clmsk),

        .i_vld      (regs.o_vld.lod),
        .i_rdy      (ex.i_rdy.lod),
        .i_regs     (regs.o_dat.lod),
        .i_msk      (regs.o_msk.lod),

        .dcache_in  (dcache_in),
        .dcache_out (dcache_out),

        .cdb_req    (cdb_req.lod),
        .ctag_msks  (ctag_msks.lod),
        .ctag_ts    (ctag_ts.lod),
        .cdb_gnt    (cdb_gnt.lod),

        .o_cands_vld(cands_vld.lod),
        .o_cands_msk(cands_msk.lod),
        .o_cands    (cands.lod)
    );

    execute2complete_str cstr_out_prekill_n;
    str_ex str_ex0 (
        .i_vld      (regs.o_vld.str),
        .i_msk      (regs.o_msk.str),
        .i_regs     (regs.o_dat.str),

        .cstr_out   (cstr_out_prekill_n)
    );

    execute2complete_bru cbru_out_prekill_n;
    bru_ex bru_ex0 (
        .i_vld      (regs.o_vld.bru),
        .i_msk      (regs.o_msk.bru),
        .i_reg      (regs.o_dat.bru),
        .btq_in     (btq_in),

        .cbru_out   (cbru_out_prekill_n),
        .o_cand_vld (cands_vld.bru),
        .o_cand_msk (cands_msk.bru),
        .o_cand     (cands.bru)
    );

    /* >> ======== STAGE 4/?: CDB data/tag broadcast ======== >> */
    // Tag broadcast occurs with CDB arbitration
    // Data broadcast is the final stage of the execute pipeline.
    execute2complete_tag ctag_out_prekill_n;
    execute2complete_dat cdat_out_prekill_n;
    assign rs_out = '{
        fu_cdb_gnt_alu  : cdb_gnt.alu,
        fu_cdb_gnt_bru  : cdb_gnt.bru | ~rs_in_fu_has_dst_bru, // a dest-less branch can always ROB-complete (via the FU's cbru_out slot)

        fu_rdy_alu      : iss.i_rdy.alu,
        fu_rdy_mul      : iss.i_rdy.mul,
        fu_rdy_lod      : iss.i_rdy.lod,
        fu_rdy_str      : iss.i_rdy.str,
        fu_rdy_bru      : iss.i_rdy.bru
    };

    assign ctag_msks_flat   = ctag_msks;
    assign ctag_ts_flat     = ctag_ts;
    for (genvar i = 0; i < NUM_FU_ALU; ++i) begin
        assign ctag_msks.alu[i] = rs_in.fu_dat_alu[i].bmask;
        assign ctag_ts.alu[i]   = rs_in.fu_dat_alu[i].t;
    end
    for (genvar i = 0; i < NUM_FU_BRU; ++i) begin
        assign ctag_msks.bru[i] = rs_in.fu_dat_bru[i].bmask;
        assign ctag_ts.bru[i]   = rs_in.fu_dat_bru[i].t;
    end

    logic [NUM_FU_TOTAL-1:0] cands_flat_has_dst;
    for (genvar f = 0; f < NUM_FU_TOTAL; ++f)
        assign cands_flat_has_dst[f] = cands_flat[f].t != `ZERO_PHYS_REG;

    logic [N-1:0][NUM_FU_TOTAL-1:0] cdb2fu_tag_sel, cdb2fu_dat_sel;
    assign cdb2fu_tag_sel = cdb2fu_gbus;
    for (genvar c = 0; c < N; ++c) begin
        assign cdb2fu_dat_sel[c] = cdb2fu_gbus_shr[1][c] & cands_flat_vldv;

        assign ctag_out_prekill_n.en[c] = |cdb2fu_gbus[c];
        assign cdat_out_prekill_n.en[c] = |cdb2fu_dat_sel[c];

        // cdb2fu assign V2:
        /* NOTE: This V2 assign follows the same principles as ffs or the tag-locate
        block in uFTB: repeatedly override whenever the bit in the select
        vector is high (instead of explicitly OR-ing them all together as in V1). 
        
        I believe V2 synthesizes to a mux, while V1 is a wide OR. In any case
        the critical path of V2 is much improved. */
        always_comb begin
            for (int f = 0; f < NUM_FU_TOTAL; ++f) begin
                if (cdb2fu_tag_sel[c][f]) begin
                    ctag_out_prekill_n.msk[c]       = ctag_msks_flat[f];
                    ctag_out_prekill_n.ts[c]        = ctag_ts_flat[f];
                end

                if (cdb2fu_dat_sel[c][f]) begin
                    cdat_out_prekill_n.msk[c]       = cands_msk[f];
                    cdat_out_prekill_n.ts[c]        = cands_flat[f].t;
                    cdat_out_prekill_n.rob_idxs[c]  = cands_flat[f].rob_idx;
                    cdat_out_prekill_n.data[c]      = cands_flat[f].data & {$bits(DATA){cands_flat_has_dst[f]}};
                        // ^ force wb's to zero register to write 0 (invariant checked in prf.sv FORMAL)
                end
            end
        end

        // cdb2fu assign V1:
        // foreach(cdb2fu_gbus_shr[_, c, f]) begin
        //     if (cdb2fu_gbus[c][f]) begin
        //         ctag_out_prekill_n.en[c]  |= 1;
        //         ctag_out_prekill_n.ts[c]  |= ctag_ts_flat[f];
        //     end

        //     if (cdb2fu_gbus_shr[1][c][f]) begin
        //         cdat_out_prekill_n.en[c]        |= cands_flat[f].vld;
        //         cdat_out_prekill_n.ts[c]        |= cands_flat[f].t;
        //         cdat_out_prekill_n.rob_idxs[c]  |= cands_flat[f].rob_idx;
        //         cdat_out_prekill_n.data[c]      |= cands_flat[f].data;
        //     end
        // end
    end


    // completion bus flops
    execute2complete_bru cbru_out_prekill;
    execute2complete_tag ctag_out_prekill;
    execute2complete_dat cdat_out_prekill;
    execute2complete_str cstr_out_prekill;
    assign cbru_out = cbru_out_prekill;
        /*
        Q: Why is cbru_out equal to cbru_out_prekill?
        A:
            1) At most one branch is completing (since NUM_FU_BRU == 1), and
            2) a branch never depends on itself
        ...so a branch completion can never kill itself.
        */
    always_comb begin
        ctag_out = ctag_out_prekill;
        for (int c = 0; c < N; ++c)
            ctag_out.en[c] = ctag_out_prekill.en[c] & ~(flush & |(ctag_out_prekill.msk[c] & clmsk));
    end
    always_comb begin
        cdat_out = cdat_out_prekill;
        for (int c = 0; c < N; ++c)
            cdat_out.en[c] = cdat_out_prekill.en[c] & ~(flush & |(cdat_out_prekill.msk[c] & clmsk));
    end
    always_comb begin
        cstr_out = cstr_out_prekill;
        for (int c = 0; c < N; ++c)
            cstr_out.en[c] = cstr_out_prekill.en[c] & ~(flush & |(cstr_out_prekill.msk[c] & clmsk));
    end

    always_ff @(posedge clock) begin
        cdb2fu_gbus_shr[0]  <= cdb2fu_gbus;
        cdb_gnt_shr[0]      <= cdb_gnt;
        for (int unsigned i = 0; i < 1; ++i) begin
            cdb2fu_gbus_shr[i+1] <= cdb2fu_gbus_shr[i];
            cdb_gnt_shr[i+1]     <= cdb_gnt_shr[i];
        end
        ctag_out_prekill    <= ctag_out_prekill_n;
        cdat_out_prekill    <= cdat_out_prekill_n;
        cbru_out_prekill    <= cbru_out_prekill_n;
        cstr_out_prekill    <= cstr_out_prekill_n;
        btq_out             <= btq_out_n;

        if (reset) begin
            cdb2fu_gbus_shr         <= '0;
            cdb_gnt_shr             <= '0;
            // FIXME: dont we need to zero out ctag ... msks as well?
            ctag_out_prekill.en     <= '0;
            cdat_out_prekill.en     <= '0;
            cstr_out_prekill.en     <= '0;

            cbru_out_prekill.en     <= '0;
            cbru_out_prekill.clmsk  <= '0;
            cbru_out_prekill.flush  <= 1'b0;
        end
    end

`ifdef FORMAL
    always_ff @(posedge clock) begin
        if (!reset) begin
            // FIXME: better to enforce this in rob.sv, where we can check duplicate dest tags over all in-flight insns
            if (ctag_out.en[0] && ctag_out.en[1]
                && ctag_out.ts[0] == ctag_out.ts[1]
                && ctag_out.ts[0] != '0) begin
                $error("💥 DUPLICATE CDB_TAG TAG: slot %0d and %0d both write tag %0d", 0, 1, ctag_out.ts[1]);
            end
            if (cdat_out.en[0] && cdat_out.en[1]
                && cdat_out.ts[0] == cdat_out.ts[1]
                && cdat_out.ts[0] != '0) begin
                $error("💥 DUPLICATE CDB_DAT tag: slot %0d and %0d both write tag %0d", 0, 1, cdat_out.ts[1]);
            end
        end
    end
`endif


`ifdef DEBUG
    task print_execute();
        $display("  %3d | >> EXECUTE", $time);

        for (int i = 0; i < NUM_FU_ALU; ++i) begin
            $display("alu_iss[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, inst: 0x%x, PC: 0x%x",
                i,
                iss.i_rdy.alu[i],
                iss.o_vld.alu[i],
                iss.o_dat.alu[i].t,
                iss.o_dat.alu[i].t1,
                iss.o_dat.alu[i].t2,
                iss.o_dat.alu[i].rob_idx,
                iss.o_dat.alu[i].inst,
                iss.o_dat.alu[i].PC
            );
        end

        for (int i = 0; i < NUM_FU_MUL; ++i) begin
            $display("mul_iss[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, func: 0x%x",
                i,
                iss.i_rdy.mul[i],
                iss.o_vld.mul[i],
                iss.o_dat.mul[i].t,
                iss.o_dat.mul[i].t1,
                iss.o_dat.mul[i].t2,
                iss.o_dat.mul[i].rob_idx,
                iss.o_dat.mul[i].func
            );
        end

        for (int i = 0; i < NUM_FU_STR; ++i) begin
            $display("str_iss[%0d]: rdy: %b, vld: %b, t1: %2d, t2: %2d, rob_idx: %2d",
                i,
                iss.i_rdy.str[i],
                iss.o_vld.str[i],
                iss.o_dat.str[i].t1,
                iss.o_dat.str[i].t2,
                iss.o_dat.str[i].rob_idx
            );
        end


        for (int i = 0; i < NUM_FU_ALU; ++i) begin
            $display("regs.o_dat.alu[%0d]: bsy: %b, rs1: 0x%x, opb: 0x%x t: %2d, rob_idx: %2d",
                i,
                regs.o_vld.alu[i],
                regs.o_dat.alu[i].opa,
                regs.o_dat.alu[i].opb,
                regs.o_dat.alu[i].t,
                regs.o_dat.alu[i].rob_idx
            );
        end

        for (int i = 0; i < NUM_FU_MUL; ++i) begin
            $display("regs.o_dat.mul[%0d]: bsy: %b, rs1: 0x%x, rs2: 0x%x t: %2d, rob_idx: %2d",
                i,
                regs.o_vld.mul[i],
                regs.o_dat.mul[i].rs1,
                regs.o_dat.mul[i].rs2,
                regs.o_dat.mul[i].t,
                regs.o_dat.mul[i].rob_idx
            );
        end

        for (int i = 0; i < NUM_FU_STR; ++i) begin
            $display("regs.o_dat.str[%0d]: bsy: %b, rs1: 0x%x, rs2: 0x%x, rob_idx: %2d",
                i,
                regs.o_vld.str[i],
                regs.o_dat.str[i].rs1,
                regs.o_dat.str[i].rs2,
                regs.o_dat.str[i].dat.rob_idx
            );
        end
        $display("$> bru_ex");
        $display("i_vld: %b", bru_ex0.i_vld);
        $display("pred: %b, pred_tgt: %x",
            btq_in.pred,
            btq_in.pred_tgt
        );
        $display("i_reg: %b", bru_ex0.i_reg);
        // $display("bytag: %b, b1hot: %b, rs1: %d, rs2: %d, PC: %x");
        // $display("opa_sel: %2d, opb_is_rs2: %b, imm32b: %d, cond_branch: %b");
        // $display("func: %d, t: %2d, rob_idx: %2d, btq_idx");
        $display("$< bru_ex");

        // $display("c_out: rdy_alu:{%b} rdy_mult:{%b} rdy_store:{%b} rdy_load:{%b}",
        //     rs_out.fu_rdy_alu,
        //     rs_out.fu_rdy_mul,
        //     rs_out.fu_rdy_str,
        //     rs_out.fu_rdy_lod,
        // );

        $display("\ncdb_req: alu:{%b} mul:{%b} lod:{%b} str:{%b}", cdb_req.alu, cdb_req.mul, cdb_req.lod, cdb_req.str);
        $display("\nctag_ts: alu:{%b} mul:{%b} lod:{%b} str:{%b}", ctag_ts.alu, ctag_ts.mul, ctag_ts.lod, ctag_ts.str);
        // $display("ctag_ts: alu:{%2d, %2d} mul:{%2d, %2d}",
        //     ctag_ts.alu[1], ctag_ts.alu[0], ctag_ts.mul[1], ctag_ts.mul[0]);
        $display("cdb_gnt: alu:{%b} mul:{%b}", cdb_gnt.alu, cdb_gnt.mul);
        for (int i = 0; i < 2; ++i) begin
            $display("cdb_gnt[%0d]: alu:{%b} mul:{%b} lod:{%b} str:{%b}",
                i,
                cdb_gnt_shr[i].alu,
                cdb_gnt_shr[i].mul,
                cdb_gnt_shr[i].lod,
                cdb_gnt_shr[i].str
            );
        end

        $display("");
        for (int n = 0; n < N; ++n) begin
            $display("cdb2fu_gbus[%0d]: %b", n, cdb2fu_gbus[n]);
        end
        for (int s = 0; s < 2; ++s) begin
            for (int n = 0; n < N; ++n) begin
                $display("cdb2fu_gbus[%0d][%0d]: %b", s, n, cdb2fu_gbus_shr[s][n]);
            end
        end

        for (int i = 0; i < N; ++i) begin
            $display("ctag_out[%0d]: en: %b, ts: %2d",
                i,
                ctag_out.en[i],
                ctag_out.ts[i],
            );
        end
        for (int i = 0; i < N; ++i) begin
            $display("cdat_out[%0d]: en: %b,  ts: %2d, rob_idxs: %2d, data: %x",
                i,
                cdat_out.en[i],
                cdat_out.ts[i],
                cdat_out.rob_idxs[i],
                cdat_out.data[i]
            );
        end

        $display("  %3d | << EXECUTE", $time);
    endtask
`endif

endmodule // stage_ex
