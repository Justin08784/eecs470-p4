

`include "sys_defs.svh"

typedef struct packed {
    logic           busy;
    logic [31:0]    inst; // debugging
    logic [6:0]     op;
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy;
    logic           t2_rdy;
} RS_ENTRY;

/*
NEED CLARIFICATION:
- Is it preferrable to have a gnt_cnt (count) instead of gnt (bus) if we force
all requests to fill the lowest indices in the req bus first (e.g. if gnt_cnt
was 2, that would mean request 0 and 1 were granted). Should we expect requests
to come in with holes (e.g. [1,0,1,0,...])?
- Should we hoist the req, gnt logic out into a backpressure slice as discussed
in the midterm system verilog question?
- Is there any circular dep./ordering issues in d_req going in, d_gnt going out,
s_req going out, s_gnt going in etc...?
*/

module rs (
    input clock,
    input reset,
    input flush,

    // dispatch
    input   logic           [`N-1:0] d_req,  // which dispatches are being requested?
    output  logic           [`N-1:0] d_gnt,  // which dispatches we accept?
    input   [31:0]          [`N-1:0] d_inst, // debugging
    input   [6:0]           [`N-1:0] d_op,
    input   PHYS_REG_IDX    [`N-1:0] d_ts,
    input   PHYS_REG_IDX    [`N-1:0] d_t1s,
    input   PHYS_REG_IDX    [`N-1:0] d_t2s,

    // issue
    output  logic           [`N-1:0] s_req,  // which issues do we request?
    input   logic           [`N-1:0] s_gnt,  // which issues are accepted?
    output  [31:0]          [`N-1:0] s_inst, // debugging
    input   [6:0]           [`N-1:0] s_op,
    output  PHYS_REG_IDX    [`N-1:0] s_ts,
    output  PHYS_REG_IDX    [`N-1:0] s_t1s,
    output  PHYS_REG_IDX    [`N-1:0] s_t2s,

    // complete (CDB)
    input   logic           [`N-1:0] c_en,
    input   PHYS_REG_IDX    [`N-1:0] c_ts

    // input allocate_en,
    // input [$bits(RS_ENTRY)-1:0] rd_allocate,
    // input cdb_en,
    // input cdb_tag,
    // // output logic tag_en,
    // // output  logic [5:0] tag,
    // output logic free_en,
    // output logic [$bits(RS_ENTRY)-1:0] wr_free,
    // output logic [$bits(ID_EX_PACKET)-1:0] inst
);


RS_ENTRY [`RS_SZ-1:0] entries;


endmodule