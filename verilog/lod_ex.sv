`include "sys_defs.svh"
`include "execute.svh"
`include "dcache.svh"

module fake_dcache #(
    parameter int NUM_RPORTS=1
) (
    input logic clock,
    input logic reset,

    // input from memory
    input  MEM_TAG       mem_in_transaction_tag,
    input  MEM_BLOCK     mem_in_data,
    input  MEM_TAG       mem_in_data_tag,

    output MEM_COMMAND   mem_out_command,
    output ADDR          mem_out_addr,
    output MEM_BLOCK     mem_out_data,

    // Load (w/ load FU)
    input  ld2dcache ld_in,
    output dcache2ld ld_out,

    // Store (w/ SQ)
    input  sq2dcache sq_in,
    output dcache2sq sq_out,

    // LDB
    output LDB ldb_out
);
    always_comb begin
        ld_out = '0;
        ld_out.status = LD_HIT_WAIT;

        sq_out = '0;
        sq_out.status = ST_FAIL;

        ldb_out = '0;
    end
endmodule

module lod_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic    [`NUM_FU_LOAD-1:0]  i_rdy,
        // ready to accept from regs.o_dat.lod?
    input  logic    [`NUM_FU_LOAD-1:0]  i_vld,
        // insns to accept from regs.o_dat.lod
    input  LOD_REGS [`NUM_FU_LOAD-1:0]  i_regs,
        // insn metadata/operands

    input  dcache2ld dcache_in,
    output ld2dcache dcache_out,
    
    input   sq2execute sq_in,
    output  execute2sq sq_out,
    output  execute2lq lq_out,
    output  executeLD2sq ld_sq_out,

    /* BACKEND */
    output logic    [`NUM_FU_LOAD-1:0]  o_vld,
    output CPL_CAND [`NUM_FU_LOAD-1:0]  o_cands,
    input  logic    [`NUM_FU_LOAD-1:0]  o_rdy 
        // completion grant
);
    /* TODO: Handling partial completes from the SQ
    If the SQ only supplies a subset of the bytes needed, then we need to get
    the rest of the bytes from the dcache.
    */
    localparam BAY_SZ = `LD_BAY_SZ;
    typedef struct packed {
        logic           vld;

        logic           queried;
        logic           hit;        // ...in cache (== !miss). Could update each cycle via recheck.
        // hit, retry 
        logic [3:0]     need_byte_mask;
        DATA_BLOCK      raw_dat;    // raw word from SQ/dcache. SHOULD NOT BE SHIFTED!
        // miss, retry
        MEM_TAG         miss_tag;   // valid iff miss_tag != 0

        // where to look / byte manip.
        LSQ_IDX         sq_idx;
        ADDR            addr;
        MEM_SIZE        mem_size;

        // CDB destination info
        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;
    } LOAD_BAY_ENTRY;
    LOAD_BAY_ENTRY  [BAY_SZ-1:0] bay, bay_n;
    logic           [BAY_SZ-1:0] bay_vld;

    // Arb: Give which free bay entry to entering, if any?
    logic [BAY_SZ-1:0]   reg2bay_gnt;
    always_comb begin
        foreach (bay_vld[i])
            bay_vld[i] = bay[i].vld;
        i_rdy[0] = |(~bay_vld);
    end

    psel_gen #(
        .WIDTH  (BAY_SZ),
        .REQS   (1)
    ) arb_reg2bay (
        .req    (~bay_vld),
        .gnt    (reg2bay_gnt)
    );

    // Arb: Who in bay gets to query (both dcache and SQ)?
    logic [BAY_SZ-1:0] bay_hit_need;     // 1. !queried || hit
    logic [BAY_SZ-1:0] bay_miss_need;    // 2. queried  && !hit
    logic [BAY_SZ-1:0] bay_req_query;
    logic [BAY_SZ-1:0] bay_gnt_query;
    always_comb begin
        foreach (bay_hit_need[i])
            bay_hit_need[i] = bay[i].vld
                && |bay[i].need_byte_mask
                && (!bay[i].queried || bay[i].hit);
        foreach (bay_miss_need[i])
            bay_miss_need[i] = bay[i].vld
                && |bay[i].need_byte_mask
                && (bay[i].queried && !bay[i].hit);

        // give priority to hit need
        bay_req_query = |bay_hit_need
            ? bay_hit_need
            : bay_miss_need;
    end
    psel_gen #(
        .WIDTH  (BAY_SZ),
        .REQS   (1)
    ) arb_query (
        .req    (~bay_req_query),
        .gnt    (bay_gnt_query)
    );

    ADDR            tmp_addr;
    MEM_SIZE        tmp_size;
    DW_ACCESS       tmp_acc;
    union packed {
        logic [3:0]     byte_level;
        logic [1:0][1:0]half_level;
        logic      [3:0]word_level;
    } tmp_bmask;

    always_comb begin
        bay_n = bay;

        foreach (reg2bay_gnt[i]) begin
            if (!(i_vld[0] && reg2bay_gnt[i]))
                continue;
            tmp_addr = i_regs[i].rs1 + i_regs[i].dat.opb;
            tmp_size = i_regs[i].dat.mem_size;
            tmp_acc = '{
                byte_off : idw_byte(tmp_addr),
                half_off : idw_half(tmp_addr),
                word_off : idw_word(tmp_addr)
            };

            tmp_bmask = '0;
            case (tmp_size)
                BYTE  : tmp_bmask.byte_level[tmp_acc.byte_off] = '1;
                HALF  : tmp_bmask.half_level[tmp_acc.half_off] = '1;
                WORD  : tmp_bmask.word_level                   = '1;
                default:;
            endcase

            bay_n[i] = '{
                vld             : 1,
                queried         : 0,
                hit             : 0,
                need_byte_mask  : tmp_bmask,
                raw_dat         : '0,
                miss_tag        : 0,
                sq_idx          : i_regs[0].dat.sq_idx,
                addr            : tmp_addr,
                mem_size        : tmp_size,
                t               : i_regs[0].dat.t,
                rob_idx         : i_regs[0].dat.rob_idx
            };
        end
    end

    // FIXME: placeholder
    assign o_vld = '0;


    /* TODO: CAND generation logic. Also, how do we know when
    a load result is ready without an lq2execute line? */
endmodule