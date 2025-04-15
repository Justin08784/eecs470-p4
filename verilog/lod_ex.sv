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
    input  logic        ld_vld,
    input  ADDR         ld_addr,
    // input  MEM_SIZE     ld_size,
    output MEM_TAG      ld_tag,
    output DATA_BLOCK   ld_dat,
    output LD_QUERY_STATUS  ld_status,

    // Store (w/ SQ)
    input  logic        st_vld,
    input  ADDR         st_addr,
    input  MEM_SIZE     st_size,
    input  DATA_BLOCK   st_dat,
    output ST_QUERY_STATUS  st_status,

    // LDB
    output LDB ldb 
);
    always_comb begin
        ld_tag = '0;
        ld_dat = '0;
        ld_status = LD_HIT_WAIT;

        st_status = ST_FAIL;

        ldb = '0;
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
    LOAD_BAY_ENTRY  [BAY_SZ-1:0] bay;
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


    /* TODO: CAND generation logic. Also, how do we know when
    a load result is ready without an lq2execute line? */
endmodule