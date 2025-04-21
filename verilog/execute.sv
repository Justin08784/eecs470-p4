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
    logic [`NUM_FU_ALU-1:0]             i_vld,
    input  ALU_REGS [`NUM_FU_ALU-1:0]   i_regs,
        // insn metadata/operands

    /* BACKEND */
    output execute2btq                  o_btq_out,
    output CPL_CAND [`NUM_FU_ALU-1:0]   o_cands
);
    ALU_OPS [`NUM_FU_ALU-1:0] ops;
    always_comb begin
        DATA opa, opb;
        foreach(ops[i]) begin
            // ALU opA mux
            case (i_regs[i].dat.opa_select)
                OPA_IS_RS1:  opa = i_regs[i].rs1;
                OPA_IS_NPC:  opa = i_regs[i].dat.NPC;
                OPA_IS_PC:   opa = i_regs[i].dat.PC;
                OPA_IS_ZERO: opa = 0;
                default:     opa = 32'hdeadface; // dead face
            endcase

            // ALU opB mux
            case (i_regs[i].dat.opb_select)
                OPB_IS_RS2:   opb =  i_regs[i].rs2;
                OPB_IS_I_IMM: opb = `RV32_signext_Iimm(i_regs[i].dat.inst);
                OPB_IS_S_IMM: opb = `RV32_signext_Simm(i_regs[i].dat.inst);
                OPB_IS_B_IMM: opb = `RV32_signext_Bimm(i_regs[i].dat.inst);
                OPB_IS_U_IMM: opb = `RV32_signext_Uimm(i_regs[i].dat.inst);
                OPB_IS_J_IMM: opb = `RV32_signext_Jimm(i_regs[i].dat.inst);
                default:      opb = 32'hfacefeed; // face feed
            endcase
            ops[i] = '{
                rs1         : i_regs[i].rs1,
                rs2         : i_regs[i].rs2,
                opa         : opa,
                opb         : opb,
                alu_func    : i_regs[i].dat.alu_func,
                branch_func : i_regs[i].dat.inst.b.funct3,
                t           : i_regs[i].dat.t,
                rob_idx     : i_regs[i].dat.rob_idx,
                btq_idx     : i_regs[i].dat.btq_idx,
                cond_branch     : i_regs[i].dat.cond_branch,
                uncond_branch   : i_regs[i].dat.uncond_branch
            };
        end
    end

    // execute
    generate
        CPL_CAND    [`NUM_FU_ALU-1:0] tmp_data;
        DATA        [`NUM_FU_ALU-1:0] tmp_res;
        logic       [`NUM_FU_ALU-1:0] cond_take, tmp_take;
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alus
            alu alu_0 ( 
                // Inputs
                .opa        (ops[i].opa),
                .opb        (ops[i].opb),
                .rs1        (ops[i].rs1),
                .rs2        (ops[i].rs2),
                .alu_func   (ops[i].alu_func),
                .branch_func(ops[i].branch_func), // Which branch condition to check

                // Output (directly to cdat_out)
                .take(cond_take[i]), // True/False condition result (will return FALSE if branch is low)
                .result(tmp_res[i]) // will return 32'hfacebeec if branch is high
            );

            assign tmp_take[i] = ops[i].uncond_branch
                || (ops[i].cond_branch && cond_take[i]);

            assign tmp_data[i] = '{
                t       : ops[i].t,
                rob_idx : ops[i].rob_idx,
                data    : tmp_take[i] ? i_regs[i].dat.NPC : tmp_res[i]
            };

            assign o_cands[i] = tmp_data[i];

            assign o_btq_out.dat[i] = '{
                en      : i_vld[i] && (ops[i].cond_branch || ops[i].uncond_branch),
                btq_idx : ops[i].btq_idx,
                take    : tmp_take[i],
                tgt     : tmp_res[i]
            };

        end
    endgenerate
endmodule


module str_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic    [`NUM_FU_STORE-1:0]  i_rdy,
    input  logic    [`NUM_FU_STORE-1:0]  i_vld,
    input  STR_REGS [`NUM_FU_STORE-1:0]  i_regs,
    
    output  execute2sq sq_out,
    // FIXME: Isn't an lq2execute needed? <-- Answer: No, if an issue is found when forwarding the SQ_IDX to LQ, it is flagged in the ROB to restart from that PC
    output  execeuteST2lq st_lq_out
);
    // FIXME: Is this right? 
    assign i_rdy = '1;

    always_comb begin
        ADDR  addr;
        foreach(i_vld[i]) begin
            // store address computation
            addr = i_regs[i].rs1 + i_regs[i].dat.opb;

            sq_out.st_ex_en[i]      = i_vld[i];
            sq_out.st_sq_idx[i]     = i_regs[i].dat.sq_idx;
            sq_out.st_addr[i]       = addr;
            sq_out.st_data[i]       = i_regs[i].rs2;
            sq_out.st_mem_size[i]   = i_regs[i].dat.mem_size;

            st_lq_out.st_en[i]      = i_vld[i];
            st_lq_out.st_sq_idx[i]  = i_regs[i].dat.sq_idx;


        end
    end

    /* TODO: CAND generation logic. */
endmodule

module mul_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic    [`NUM_FU_MULT-1:0]  i_rdy,
        // ready to accept from regs.o_dat.mul?
    input  logic    [`NUM_FU_MULT-1:0]  i_vld,
        // insns to accept from regs.o_dat.mul
    input  MUL_REGS [`NUM_FU_MULT-1:0]  i_regs,
        // insn metadata/operands

    /* Early CDB arbitration */
    output logic [`NUM_FU_MULT-1:0]     cdb_req,
    output PHYS_REG_IDX [`NUM_FU_MULT-1:0] ctag_ts,
    input  logic [`NUM_FU_MULT-1:0]     cdb_gnt,

    /* BACKEND */
    output CPL_CAND [`NUM_FU_MULT-1:0]  o_cands
);
    MUL_OPS [`NUM_FU_MULT-1:0] ops;
    always_comb begin
        foreach (ops[i]) begin
            ops[i] = '{
                rs1     : i_regs[i].rs1,
                rs2     : i_regs[i].rs2,
                func    : i_regs[i].dat.func,
                t       : i_regs[i].dat.t,
                rob_idx : i_regs[i].dat.rob_idx
            };
            // $display("MULT_FUNC: %0d", i_regs[i].dat.func);
        end
    end

    // execute
    generate
        DATA        [`NUM_FU_MULT-1:0] tmp_res;
        PHYS_REG_IDX[`NUM_FU_MULT-1:0] tmp_t;
        ROB_IDX     [`NUM_FU_MULT-1:0] tmp_rob_idx;

        logic       [`NUM_FU_MULT-1:0] cpl_buf_rdy;
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mults
            mult #(
                .ID(i)
            ) mult_0 ( 
                .clock  (clock),
                .reset  (reset),
                .flush  (flush),

                .i_vld  (i_vld[i]),
                .i_rdy  (i_rdy[i]),
                .rs1    (ops[i].rs1),
                .rs2    (ops[i].rs2),
                .func   (ops[i].func),
                .i_t    (ops[i].t),
                .i_rob_idx(ops[i].rob_idx),

                .cdb_req(cdb_req[i]),
                .ctag_t (ctag_ts[i]),
                .cdb_gnt(cdb_gnt[i]),

                // Output (directly to cdat_out)
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

module stage_ex_p4 (
    `ifdef DEBUG
    input  logic print_en,
    output DBG_execute dbg,
    `endif
    input clock,
    input reset,
    input flush,

    input   rs2execute rs_in,
    output  execute2rs rs_out,

    input   sq2execute sq_in,
    output  execute2sq sq_out,
    // FIXME: Isn't an lq2execute needed?
    output  execute2lq lq_out,
    output  execeuteST2lq st_lq_out,
    output  executeLD2sq ld_sq_out,

    input   dcache2ld   dcache_in,
    output   ld2dcache   dcache_out,

    input   prf2execute prf_in,
    output  execute2prf prf_out,

    output  execute2btq btq_out,

    output  execute2complete_tag ctag_out,
    output  execute2complete_dat cdat_out

);
    /* >> ======== STAGE 1: Issue Staging ======== >> */
    // (where just-issued insns wait for 1 cycle)
    struct packed {
        `BY_FU(logic)   i_rdy;
        `BY_FU(logic)   o_vld;
        struct packed {
            ID_ALU_VIEW [`NUM_FU_ALU-1:0]   alu;
            ID_MUL_VIEW [`NUM_FU_MULT-1:0]  mul;
            ID_LOD_VIEW [`NUM_FU_LOAD-1:0]  lod;
            ID_STR_VIEW [`NUM_FU_STORE-1:0] str;
        } i_dat, o_dat;
    } iss;

    struct packed {
        `BY_FU(logic) i_rdy;
        `BY_FU(logic) o_vld;
        struct packed {
            ALU_REGS [`NUM_FU_ALU-1:0]   alu;
            MUL_REGS [`NUM_FU_MULT-1:0]  mul;
            LOD_REGS [`NUM_FU_LOAD-1:0]  lod;
            STR_REGS [`NUM_FU_STORE-1:0] str;
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
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alu_sbufs
            assign iss.i_dat.alu[i] = '{
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

            assign iss.i_rdy.alu[i] = 1;
            flop #(
                .WIDTH($bits(ID_ALU_VIEW))
            ) sbuf_alu (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_alu[i]),
                .i_dat (iss.i_dat.alu[i]),

                .o_vld (iss.o_vld.alu[i]),
                .o_dat (iss.o_dat.alu[i])
            );
        end
        
        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mul_sbufs
            assign iss.i_dat.mul[i] = '{
                t       : rs_in.fu_dat_mult[i].t,
                t1      : rs_in.fu_dat_mult[i].t1,
                t2      : rs_in.fu_dat_mult[i].t2,
                rob_idx : rs_in.fu_dat_mult[i].rob_idx,
                func    : rs_in.fu_dat_mult[i].inst.r.funct3
            };

            ppln_skid #(
                .WIDTH($bits(ID_MUL_VIEW))
            ) sbuf_mul (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_mult[i]),
                .i_rdy (iss.i_rdy.mul[i]),
                .i_dat (iss.i_dat.mul[i]),

                .o_vld (iss.o_vld.mul[i]),
                .o_rdy (regs.i_rdy.mul[i]),
                .o_dat (iss.o_dat.mul[i])
            );
        end

        for (genvar i = 0; i < `NUM_FU_LOAD; ++i) begin : gen_lod_sbufs
            assign iss.i_dat.lod[i] = '{
                t       : rs_in.fu_dat_load[i].t,
                t1      : rs_in.fu_dat_load[i].t1,
                opb     : `RV32_signext_Iimm(rs_in.fu_dat_load[i].inst),

                lq_idx  : rs_in.fu_dat_load[i].lq_idx,
                sq_idx  : rs_in.fu_dat_load[i].sq_idx,
                rob_idx : rs_in.fu_dat_load[i].rob_idx,
                mem_size: MEM_SIZE'(rs_in.fu_dat_load[i].inst.r.funct3[1:0]),
                rd_unsigned : rs_in.fu_dat_load[i].inst.r.funct3[2]
            };

            ppln_skid #(
                .WIDTH($bits(ID_LOD_VIEW))
            ) sbuf_lod (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_load[i]),
                .i_rdy (iss.i_rdy.lod[i]),
                .i_dat (iss.i_dat.lod[i]),

                .o_vld (iss.o_vld.lod[i]),
                .o_rdy (regs.i_rdy.lod[i]),
                .o_dat (iss.o_dat.lod[i])
            );
        end

        for (genvar i = 0; i < `NUM_FU_STORE; ++i) begin : gen_str_sbufs
            assign iss.i_dat.str[i] = '{
                t1      : rs_in.fu_dat_store[i].t1,
                t2      : rs_in.fu_dat_store[i].t2,
                opb     : `RV32_signext_Simm(rs_in.fu_dat_store[i].inst),

                sq_idx  : rs_in.fu_dat_store[i].sq_idx,
                rob_idx : rs_in.fu_dat_store[i].rob_idx,
                mem_size: MEM_SIZE'(rs_in.fu_dat_store[i].inst.r.funct3[1:0])
            };

            ppln_skid #(
                .WIDTH($bits(ID_STR_VIEW))
            ) sbuf_str (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (rs_in.fu_en_store[i]),
                .i_rdy (iss.i_rdy.str[i]),
                .i_dat (iss.i_dat.str[i]),

                .o_vld (iss.o_vld.str[i]),
                .o_rdy (regs.i_rdy.str[i]),
                .o_dat (iss.o_dat.str[i])
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
    end

    struct packed {
        `BY_FU(logic) i_rdy;
    } ex;
    always_comb begin
        foreach (iss.o_vld.alu[i]) begin
            regs.i_dat.alu[i] = '{
                rs1 : prf_in.v1s.alu[i],
                rs2 : prf_in.v2s.alu[i],
                dat : iss.o_dat.alu[i]
            };
        end
        foreach (iss.o_vld.mul[i]) begin
            regs.i_dat.mul[i] = '{
                rs1 : prf_in.v1s.mul[i],
                rs2 : prf_in.v2s.mul[i],
                dat : iss.o_dat.mul[i]
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
                rs1 : prf_in.v1s.str[i],
                rs2 : prf_in.v2s.str[i],
                dat : iss.o_dat.str[i]
            };
        end
    end

    generate
        assign regs.i_rdy.alu = '1;
        for (genvar i = 0; i < `NUM_FU_ALU; ++i) begin : gen_alu_rbufs
            /* Unlike mul, lod, str, we *shouldn't* need snooping to feed back
            into rbuf (via i_snoop) because we *should* never stall post issue. */
            ALU_REGS raw;
            flop #(
                .WIDTH($bits(ALU_REGS))
            ) rbuf_alu (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld (iss.o_vld.alu[i]),
                .i_dat (regs.i_dat.alu[i]),

                .o_vld (regs.o_vld.alu[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.alu[i] = alu_snoop(raw, cdat_out);
        end

        for (genvar i = 0; i < `NUM_FU_MULT; ++i) begin : gen_mul_rbufs
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

                .i_snoop(regs.o_dat.mul[i]),

                .i_vld (iss.o_vld.mul[i]),
                .i_rdy (regs.i_rdy.mul[i]),
                .i_dat (regs.i_dat.mul[i]),

                .o_vld (regs.o_vld.mul[i]),
                .o_rdy (ex.i_rdy.mul[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.mul[i] = mul_snoop(raw, cdat_out);
        end

        for (genvar i = 0; i < `NUM_FU_LOAD; ++i) begin : gen_lod_rbufs
            LOD_REGS raw;
            skid #(
                .ENABLE_SNOOP(`TRUE),
                .WIDTH($bits(LOD_REGS))
            ) rbuf_lod (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_snoop(regs.o_dat.lod[i]),

                .i_vld (iss.o_vld.lod[i]),
                .i_rdy (regs.i_rdy.lod[i]),
                .i_dat (regs.i_dat.lod[i]),

                .o_vld (regs.o_vld.lod[i]),
                .o_rdy (ex.i_rdy.lod[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.lod[i] = lod_snoop(raw, cdat_out);
        end

        for (genvar i = 0; i < `NUM_FU_STORE; ++i) begin : gen_str_rbufs
            STR_REGS raw;
            skid #(
                .ENABLE_SNOOP(`TRUE),
                .WIDTH($bits(STR_REGS))
            ) rbuf_str (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_snoop(regs.o_dat.str[i]),

                .i_vld (iss.o_vld.str[i]),
                .i_rdy (regs.i_rdy.str[i]),
                .i_dat (regs.i_dat.str[i]),

                .o_vld (regs.o_vld.str[i]),
                .o_rdy (ex.i_rdy.str[i]),
                .o_dat (raw)
            );
            assign regs.o_dat.str[i] = str_snoop(raw, cdat_out);
        end
    endgenerate

    /* >> ======== STAGE ?: (early) CDB arbitration ======== >> */
    // If 1-cycle operation (e.g. ALU), this is before issue staging.
    // Else if a longer-latency insn, this is in the middle of execution.

    `BY_FU(CPL_CAND) cands;
    assign cands.str = '0; // alu, mul, lod set by respective *_ex's
    CPL_CAND [`NUM_FU_TOTAL-1:0] cands_flat;
    assign cands_flat = cands;
    
    /*
    Complete grant bus shift register
    */
    logic [1:0][`N-1:0][`NUM_FU_TOTAL-1:0]  cdb2fu_gbus_shr;
    logic [`N-1:0][`NUM_FU_TOTAL-1:0]       cdb2fu_gbus;
    `BY_FU(logic) [1:0] cdb_gnt_shr;

    `BY_FU(logic) cdb_req;
    assign cdb_req.alu = rs_in.fu_vld_alu;
    // cdb_req.mul set by mul_ex
    // cdb_req.lod set by lod_ex
    assign cdb_req.str = '0;
    `BY_FU(logic) cdb_gnt;

    psel_gen #(
        .WIDTH(`NUM_FU_TOTAL),
        .REQS(`N)
    ) cdb_arb (
        .req    (cdb_req),  // flatten (alu + mul bits) => single [NUM_FU_TOTAL-1:0] bus
        .gnt    (cdb_gnt),  // flatten => single bus
        .gnt_bus(cdb2fu_gbus)
    );
    
    /* >> ======== STAGE 3: Execution ======== >> */
    // Includes operand decode/CDB bypass just before 1st cycle of execution.

    execute2btq btq_out_n;
    alu_ex alu_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .i_vld  (regs.o_vld.alu),
        .i_regs (regs.o_dat.alu),

        .o_btq_out(btq_out_n),
        .o_cands(cands.alu)
    );

    `BY_FU(PHYS_REG_IDX) ctag_ts;
    PHYS_REG_IDX [`NUM_FU_TOTAL-1:0] ctag_ts_flat;
    
    mul_ex mul_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .i_vld  (regs.o_vld.mul),
        .i_regs (regs.o_dat.mul),
        .i_rdy  (ex.i_rdy.mul),

        .cdb_req(cdb_req.mul),
        .ctag_ts(ctag_ts.mul),
        .cdb_gnt(cdb_gnt.mul),

        .o_cands(cands.mul)
    );

    lod_ex lod_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .i_rdy  (ex.i_rdy.lod),
        .i_vld  (regs.o_vld.lod),
        .i_regs (regs.o_dat.lod),

        .sq_in(sq_in),
        .lq_out(lq_out),
        .ld_sq_out(ld_sq_out),

        .dcache_in(dcache_in),
        .dcache_out(dcache_out),

        .cdb_req(cdb_req.lod),
        .ctag_ts(ctag_ts.lod),
        .cdb_gnt(cdb_gnt.lod),
        
        .o_cands(cands.lod)
    );

    str_ex str_ex0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .i_vld  (regs.o_vld.str),
        .i_regs (regs.o_dat.str),
        .i_rdy  (ex.i_rdy.str),

        .sq_out(sq_out),
        .st_lq_out(st_lq_out)
    );

    /* >> ======== STAGE 4/?: CDB data/tag broadcast ======== >> */
    // Tag broadcast occurs with CDB arbitration
    // Data broadcast is the final stage of the execute pipeline.
    execute2complete_tag ctag_out_n;
    execute2complete_dat cdat_out_n;
    always_comb begin
        rs_out = '{
            fu_cdb_gnt_alu  : cdb_gnt.alu,

            fu_rdy_alu      : iss.i_rdy.alu,
            fu_rdy_mult     : iss.i_rdy.mul,
            fu_rdy_load     : iss.i_rdy.lod,
            fu_rdy_store    : iss.i_rdy.str
        };

        foreach (rs_in.fu_dat_alu[i])
            ctag_ts.alu[i] = rs_in.fu_dat_alu[i].t;
        ctag_ts_flat = ctag_ts;

        ctag_out_n = '0;
        cdat_out_n = '0;
        foreach(cdb2fu_gbus_shr[_, c, f]) begin
            if (cdb2fu_gbus[c][f]) begin
                ctag_out_n.en[c]  |= 1;
                ctag_out_n.ts[c]  |= ctag_ts_flat[f];
            end

            if (cdb2fu_gbus_shr[1][c][f]) begin
                cdat_out_n.en[c]        |= 1;
                cdat_out_n.ts[c]        |= cands_flat[f].t;
                cdat_out_n.rob_idxs[c]  |= cands_flat[f].rob_idx;
                cdat_out_n.data[c]      |= cands_flat[f].data;
            end

        end
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            cdb2fu_gbus_shr <= '0;
            cdb_gnt_shr     <= '0;
            ctag_out        <= '0;
            cdat_out        <= '0;
            btq_out         <= '0;
        end else begin
            cdb2fu_gbus_shr[0]  <= cdb2fu_gbus;
            cdb_gnt_shr[0]      <= cdb_gnt;
            for (int unsigned i = 0; i < 1; ++i) begin
                cdb2fu_gbus_shr[i+1] <= cdb2fu_gbus_shr[i];
                cdb_gnt_shr[i+1]     <= cdb_gnt_shr[i];
            end
            ctag_out <= ctag_out_n;
            cdat_out <= cdat_out_n;
            btq_out  <= btq_out_n;

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

    // `ifdef DEBUG
    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("  %3d | >> EXECUTE", $time);

    //         for (int i = 0; i < `NUM_FU_ALU; ++i) begin
    //             $display("alu_iss[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, btq_idx: %2d, inst: 0x%x, PC: 0x%x, NPC: 0x%x, cond_branch: %b, uncond_branch: %b",
    //                 i,
    //                 iss.i_rdy.alu[i],
    //                 iss.o_vld.alu[i],
    //                 iss.o_dat.alu[i].t,
    //                 iss.o_dat.alu[i].t1,
    //                 iss.o_dat.alu[i].t2,
    //                 iss.o_dat.alu[i].rob_idx,
    //                 iss.o_dat.alu[i].btq_idx,
    //                 iss.o_dat.alu[i].inst,
    //                 iss.o_dat.alu[i].PC,
    //                 iss.o_dat.alu[i].NPC,
    //                 iss.o_dat.alu[i].cond_branch,
    //                 iss.o_dat.alu[i].uncond_branch
    //             );
    //         end

    //         for (int i = 0; i < `NUM_FU_MULT; ++i) begin
    //             $display("mul_iss[%0d]: rdy: %b, vld: %b, t: %2d, t1: %2d, t2: %2d, rob_idx: %2d, func: 0x%x",
    //                 i,
    //                 iss.i_rdy.mul[i],
    //                 iss.o_vld.mul[i],
    //                 iss.o_dat.mul[i].t,
    //                 iss.o_dat.mul[i].t1,
    //                 iss.o_dat.mul[i].t2,
    //                 iss.o_dat.mul[i].rob_idx,
    //                 iss.o_dat.mul[i].func
    //             );
    //         end

    //         for (int i = 0; i < `NUM_FU_ALU; ++i) begin
    //             $display("regs.o_dat.alu[%0d]: bsy: %b, rs1: 0x%x, rs2: 0x%x t: %2d, rob_idx: %2d, btq_idx: %2d",
    //                 i,
    //                 regs.o_vld.alu[i],
    //                 regs.o_dat.alu[i].rs1,
    //                 regs.o_dat.alu[i].rs2,
    //                 regs.o_dat.alu[i].dat.t,
    //                 regs.o_dat.alu[i].dat.rob_idx,
    //                 regs.o_dat.alu[i].dat.btq_idx
    //             );
    //         end

    //         for (int i = 0; i < `NUM_FU_MULT; ++i) begin
    //             $display("regs.o_dat.mul[%0d]: bsy: %b, rs1: 0x%x, rs2: 0x%x t: %2d, rob_idx: %2d",
    //                 i,
    //                 regs.o_vld.mul[i],
    //                 regs.o_dat.mul[i].rs1,
    //                 regs.o_dat.mul[i].rs2,
    //                 regs.o_dat.mul[i].dat.t,
    //                 regs.o_dat.mul[i].dat.rob_idx
    //             );
    //         end

    //         $display("c_out: rdy_alu:{%b} rdy_mult:{%b} rdy_store:{%b} rdy_load:{%b}",
    //             rs_out.fu_rdy_alu,
    //             rs_out.fu_rdy_mult,
    //             rs_out.fu_rdy_store,
    //             rs_out.fu_rdy_load,
    //         );

    //         $display("\ncdb_req: alu:{%b} mul:{%b} lod:{%b} str:{%b}", cdb_req.alu, cdb_req.mul, cdb_req.lod, cdb_req.str);
    //         $display("\nctag_ts: alu:{%b} mul:{%b} lod:{%b} str:{%b}", ctag_ts.alu, ctag_ts.mul, ctag_ts.lod, ctag_ts.str);
    //         // $display("ctag_ts: alu:{%2d, %2d} mul:{%2d, %2d}",
    //         //     ctag_ts.alu[1], ctag_ts.alu[0], ctag_ts.mul[1], ctag_ts.mul[0]);
    //         $display("cdb_gnt: alu:{%b} mul:{%b}", cdb_gnt.alu, cdb_gnt.mul);
    //         for (int i = 0; i < 2; ++i) begin
    //             $display("cdb_gnt[%0d]: alu:{%b} mul:{%b} lod:{%b} str:{%b}",
    //                 i,
    //                 cdb_gnt_shr[i].alu,
    //                 cdb_gnt_shr[i].mul,
    //                 cdb_gnt_shr[i].lod,
    //                 cdb_gnt_shr[i].str
    //             );
    //         end

    //         $display("");
    //         for (int n = 0; n < `N; ++n) begin
    //             $display("cdb2fu_gbus[%0d]: %b", n, cdb2fu_gbus[n]);
    //         end
    //         for (int s = 0; s < 2; ++s) begin
    //             for (int n = 0; n < `N; ++n) begin
    //                 $display("cdb2fu_gbus[%0d][%0d]: %b", s, n, cdb2fu_gbus_shr[s][n]);
    //             end
    //         end


    //         for (int i = 0; i < `N; ++i) begin
    //             $display("ctag_out_n[%0d]: en: %b, ts: %2d",
    //                 i,
    //                 ctag_out_n.en[i],
    //                 ctag_out_n.ts[i],
    //             );
    //         end
    //         for (int i = 0; i < `N; ++i) begin
    //             $display("ctag_out[%0d]: en: %b, ts: %2d",
    //                 i,
    //                 ctag_out.en[i],
    //                 ctag_out.ts[i],
    //             );
    //         end
    //         for (int i = 0; i < `N; ++i) begin
    //             $display("cdat_out[%0d]: en: %b,  ts: %2d, rob_idxs: %2d, data: %x",
    //                 i,
    //                 cdat_out.en[i],
    //                 cdat_out.ts[i],
    //                 cdat_out.rob_idxs[i],
    //                 cdat_out.data[i]
    //             );
    //         end

    //         $display("<prf_in >        v1s: [%0d, %0d, %0d, %0d] v2s: [%0d, %0d, %0d, %0d]",
    //             prf_in.v1s[0],
    //             prf_in.v1s[1],
    //             prf_in.v1s[2],
    //             prf_in.v1s[3],
    //             prf_in.v2s[0],
    //             prf_in.v2s[1],
    //             prf_in.v2s[2],
    //             prf_in.v2s[3]
    //         );
    //         $display("  %3d | << EXECUTE", $time);
    //     end
    // end
    // `endif // DEBUG
    `ifdef DEBUG
    assign dbg = '{
        btq_out : btq_out,
        ctag_out: ctag_out,
        cdat_out: cdat_out,
        iss     : iss,
        regs    : regs,

        cands   : cands,
        cands_flat      : cands_flat,

        ctag_ts : ctag_ts,
        ctag_ts_flat : ctag_ts_flat,

        cdb2fu_gbus_shr : cdb2fu_gbus_shr,
        cdb2fu_gbus : cdb2fu_gbus,
        cdb_gnt_shr : cdb_gnt_shr,

        cdb_req : cdb_req,
        cdb_gnt : cdb_gnt
    };
    `endif

endmodule // stage_ex
