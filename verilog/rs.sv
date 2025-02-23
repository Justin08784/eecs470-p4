

`include "sys_defs.svh"

typedef enum logic [1:0] {
    FU_ALU  = 2'b00,
    FU_MULT = 2'b01,
    FU_LOAD = 2'b10,
    FU_STOR = 2'b11
} FU_IDX;
`define FU_IDX_NUM 4

typedef struct packed {
    logic           busy;
    logic           issued;
    logic [31:0]    inst; // debugging
    logic [6:0]     op;
    FU_IDX          fu_idx;
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy; // ready in ROB?
    logic           t2_rdy;
} RS_ENTRY;

// functional unit availability
// saturating counters that cap at N
typedef struct packed {
    logic [$clog2(`N):0] alu_cnt;
    logic [$clog2(`N):0] mult_cnt;
    logic [$clog2(`N):0] load_cnt;
    logic [$clog2(`N):0] stor_cnt;
} FU_AVAIL;

/*
NEED CLARIFICATION:
- Is it preferrable to have a gnt_cnt (count) instead of gnt (bus) if we force
all requests to fill the lowest indices in the req bus first (e.g. if gnt_cnt
was 2, that would mean request 0 and 1 were granted). Should we expect requests
to come in with holes (e.g. [1,0,1,0,...])?
- Should we hoist the req, gnt logic out into a backpressure slice as discussed
in the midterm system verilog question?
- Is there any circular dep./ordering issues in d_vld going in, d_gnt going out,
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

    /*
    rs_free_cnt saturates at N (Why? A: even if we have more free RS entries 
    than N, we can only dispatch at most N each cycle anyways).

    e.g. N = 2
    logic [1:0] rs_free_cnt;
    b00 +> b01 +> b10 (cannot increment further)
    0      1      2 
    */
    output  logic           [$clog2(`N):0] rs_free_cnt, // to dispatcher
    input   logic           [`N-1:0] d_vld,     // which dispatch lines are valid? (from dispatcher; dep. on rs_free_cnt)
    input   [31:0]          [`N-1:0] d_inst,    // debugging
    input   [6:0]           [`N-1:0] d_op,
    input   FU_IDX          [`N-1:0] d_fu_idx,
    /* CONCERN 1:
    What data do we actually need to store in the RS so that it can immediately
    execute after issue to an FU? Like I'm looking at the fields of ID_EX_PACKET
    and they are considerable?
    */
    input   PHYS_REG_IDX    [`N-1:0] d_ts,
    input   PHYS_REG_IDX    [`N-1:0] d_t1s,
    input   PHYS_REG_IDX    [`N-1:0] d_t2s,
    input   PHYS_REG_IDX    [`N-1:0] d_t1_rdys,
    input   PHYS_REG_IDX    [`N-1:0] d_t2_rdys,

    // issue
    input   logic           [$clog2(`N):0][`FU_IDX_NUM-1:0] fu_avail,
    output  logic           [`N-1:0] s_vld,     // which issue lines are valid? (dep. on fu_avail)
    output  [31:0]          [`N-1:0] s_inst,    // debugging
    output  [6:0]           [`N-1:0] s_op,
    output  FU_IDX          [`N-1:0] s_fu_idx,
    /* Ditto CONCERN 1 */
    output  PHYS_REG_IDX    [`N-1:0] s_ts,
    output  PHYS_REG_IDX    [`N-1:0] s_t1s,
    output  PHYS_REG_IDX    [`N-1:0] s_t2s,

    // complete (CDB)
    /*
    Mustafa:
    implement backpressure from the CDB (one of tips in slides apparently?)
    (make a rdy-vld handshake between FUs and reservation stations)
    */
    input   logic           [`N-1:0] c_en,
    input   PHYS_REG_IDX    [`N-1:0] c_ts

);
    RS_ENTRY [`RS_SZ-1:0] entries;

    logic [`RS_SZ-1:0] busy_vec;
    logic [`RS_SZ-1:0] issd_vec;
    generate
    for (genvar i = 0; i < `RS_SZ; i++) begin : gen_vecs
        assign busy_vec[i] = entries[i].busy;
        assign issd_vec[i] = entries[i].issued;
    end
    endgenerate

    logic [`RS_SZ-1:0] to_issue;
    always_comb begin
        logic [$clog2(`N):0][`FU_IDX_NUM-1:0] fu_cnts = fu_avail;
        s_vld = '0;
        to_issue = '0;

        for (int i = 0, int cnt = 0; i < `RS_SZ; ++i) begin
            // issued up to width
            if (cnt > `N)
                break;

            // not ready to issue
            if (fu_cnts[entries[i].fu_idx] == 0
                || !entries[i].t1_rdy
                || !entries[i].t2_rdy)
                continue;

            to_issue[i]     = 1;
            s_vld[cnt]      = 1;
            s_fu_idx[cnt]   = entries[i].fu_idx;
            s_ts[cnt]       = entries[i].t;
            s_t1s[cnt]      = entries[i].t1;
            s_t2s[cnt]      = entries[i].t2;
            ++fu_cnts[entries[i].fu_idx];
            ++cnt;
        end
    end

    logic [`RS_SZ-1:0] free_entries;
    assign free_entries = 
        ~busy_vec
        | issd_vec; // an issued insn will go to EX and free its entry


    logic [`RS_SZ-1:0][`N-1:0]  free_gnt_bus;
    logic [`RS_SZ-1:0]          free_gnt;
    psel_gen #(
        .WIDTH(`RS_SZ),
        .REQS(`N)
    ) entries_psel (
        .req    (free_entries),
        .gnt    (free_gnt),
        .gnt_bus(free_gnt_bus)
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
            if (d_vld[i])
                d_gnt_bus[i] |= free_gnt_bus[i];
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
                    entries[i].fu_idx   <= d_fu_idx[j];
                    entries[i].t        <= d_ts[j];
                    entries[i].t1       <= d_t1s[j];
                    entries[i].t2       <= d_t2s[j];
                    entries[i].t1_rdy   <= d_t1_rdys[j];
                    entries[i].t2_rdy   <= d_t2_rdys[j];
                end else if (issd_vec[i]) begin
                    entries[i]          <= '0;
                end
            end
        end
    end


endmodule