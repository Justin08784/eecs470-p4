

`include "sys_defs.svh"

typedef struct packed {
    logic           busy;
    logic           issued;
    logic [31:0]    inst; // debugging
    logic [6:0]     op;
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy; // ready in ROB?
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
    /*
    Mustafa, Tip:
    make dispatch logic (i.e. dispatch or not?)a separate module 
    (cuz you need to check struct hazards in ROB as well)
    */

    output  logic           [$clog2(`N)-1:0] rs_free_cnt;
    input   logic           [`N-1:0] d_req,  // which dispatches are being requested?
    input   [31:0]          [`N-1:0] d_inst, // debugging
    input   [6:0]           [`N-1:0] d_op,
    input   PHYS_REG_IDX    [`N-1:0] d_ts,
    input   PHYS_REG_IDX    [`N-1:0] d_t1s,
    input   PHYS_REG_IDX    [`N-1:0] d_t2s,
    input   PHYS_REG_IDX    [`N-1:0] d_t1_rdys,
    input   PHYS_REG_IDX    [`N-1:0] d_t2_rdys,
    output  logic           [`N-1:0] d_gnt,  // which dispatches we accept?

    // issue
    output  logic           [`RS_SZ-1:0] s_req,  // which issues do we request?
    output  [31:0]          [`RS_SZ-1:0] s_inst, // debugging
    output  [6:0]           [`RS_SZ-1:0] s_op,
    output  PHYS_REG_IDX    [`RS_SZ-1:0] s_ts,
    output  PHYS_REG_IDX    [`RS_SZ-1:0] s_t1s,
    output  PHYS_REG_IDX    [`RS_SZ-1:0] s_t2s,
    input   [`RS_SZ-1:0]    [`N-1:0] s_gnt,      // which issues are accepted?

    // complete (CDB)
    /*
    Mustafa:
    implement backpressure from the CDB (one of tips in slides apparently?)
    (make a rdy-vld handshake between FUs and reservation stations)
    */
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

    logic [`RS_SZ-1:0] busy_vec;
    logic [`RS_SZ-1:0] issued_vec;
    generate
    for (genvar i = 0; i < `RS_SZ; i++) begin : gen_vecs
        assign busy_vec[i]      = entries[i].busy;
        assign issued_vec[i]    = entries[i].issued;
    end
    endgenerate

    logic [`RS_SZ-1:0] free_entries;
    assign free_entries = 
        ~busy_vec
        | issued_vec; // an issued insn will go to EX and free its entry


    logic [`RS_SZ-1:0][`N-1:0]  entries_gnt_bus;
    logic [`RS_SZ-1:0]          entries_gnt;
    psel_gen #(
        .WIDTH(`RS_SZ),
        .REQS(`N)
    ) entries_psel (
        .req    (free_entries),
        .gnt    (entries_gnt),
        .gnt_bus(entries_gnt_bus)
        // .empty()
    );

    /*
    Mustafa:
    if you make it alternating it might dispatch younger insns
    so just make it a dependent for-loop (i.e. serial); it shouldnt
    be too big of a deal. But possible room for optimization 
    by making it a lowest-index first priority encoder?
    */
    logic [`RS_SZ-1:0][`N-1:0]  d_gnt_bus;
    always_comb begin
        d_gnt_bus = '0;
        for (int i = 0; i < `N; ++i) begin
            if (d_req[i]) begin
                d_gnt[i]        = (entries_gnt_bus[i] != 0); 
                d_gnt_bus[i]    |= entries_gnt_bus[i];
            end
        end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            entries <= '0;
        end else begin
            foreach (d_gnt_bus[i, j]) begin
                if (d_gnt_bus[i][j]) begin
                    entries[i].busy     <= 1;
                    entries[i].issued   <= 0;
                    entries[i].inst     <= d_inst[j];
                    entries[i].op       <= d_op[j];
                    entries[i].t        <= d_ts[j];
                    entries[i].t1       <= d_t1s[j];
                    entries[i].t2       <= d_t2s[j];
                    entries[i].t1_rdy   <= d_t1_rdys[j];
                    entries[i].t2_rdy   <= d_t2_rdys[j];
                end else if (issued_vec[i]) begin
                    entries[i]          <= '0;
                end
            end
        end
    end


endmodule