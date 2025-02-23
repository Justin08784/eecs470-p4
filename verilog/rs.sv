

`include "sys_defs.svh"

typedef enum logic [1:0] {
    FU_ALU  = 2'b00,
    FU_MULT = 2'b01,
    FU_LOAD = 2'b10,
    FU_STOR = 2'b11
} FU_IDX;
`define FU_IDX_NUM 4

typedef struct packed {
    PHYS_REG_IDX    t;
    PHYS_REG_IDX    t1;
    PHYS_REG_IDX    t2;
    logic           t1_rdy; // ready in ROB?
    logic           t2_rdy;
    FU_IDX          fu_idx;

    /* from ID_EX_PACKET */
    INST inst;
    ADDR PC;
    ADDR NPC; // PC + 4

    // DATA rs1_value; // reg A value
    // DATA rs2_value; // reg B value

    ALU_OPA_SELECT opa_select; // ALU opa mux select (ALU_OPA_xxx *)
    ALU_OPB_SELECT opb_select; // ALU opb mux select (ALU_OPB_xxx *)

    // REG_IDX  dest_reg_idx;  // destination (writeback) register index
    ALU_FUNC alu_func;      // ALU function select (ALU_xxx *)
    logic    mult;          // Is inst a multiply instruction?
    logic    rd_mem;        // Does inst read memory?
    logic    wr_mem;        // Does inst write memory?
    logic    cond_branch;   // Is inst a conditional branch?
    logic    uncond_branch; // Is inst an unconditional branch?
    logic    halt;          // Is this a halt?
    logic    illegal;       // Is this instruction illegal?
    logic    csr_op;        // Is this a CSR operation? (we only used this as a cheap way to get return code)

    // logic    valid;
} ID_RESULT;

typedef struct packed {
    logic           busy;
    logic           issued;
    ID_RESULT       dat;
} RS_ENTRY;


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
    rs_scnt saturates at N (Why? A: even if we have more free RS entries 
    than N, we can only dispatch at most N each cycle anyways).

    e.g. N = 2
    logic [1:0] rs_scnt;
    b00 +> b01 +> b10 (cannot increment further)
    0      1      2 
    */
    output  logic           [$clog2(`N):0] rs_scnt, // to dispatcher
    input   logic           [`N-1:0] d_vld,     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    input   ID_RESULT       [`N-1:0] d_dat,
    /* CONCERN 1:
    What data do we actually need to store in the RS so that it can immediately
    execute after issue to an FU? Like I'm looking at the fields of ID_EX_PACKET
    and they are considerable?
    */

    // issue
    input   logic           [$clog2(`N):0][`FU_IDX_NUM-1:0] fu_scnt, // functional unit availability; saturating counters that cap at N
    output  logic           [`N-1:0] s_vld,     // which issue lines are valid? (dep. on fu_scnt)
    output  ID_RESULT       [`N-1:0] s_dat,
    /* Ditto CONCERN 1 */

    // complete (CDB)
    /*
    Mustafa:
    implement backpressure from the CDB (one of tips in slides apparently?)
    (make a rdy-vld handshake between FUs and reservation stations)
    */
    input   logic           [`N-1:0] c_en,
    input   PHYS_REG_IDX    [`N-1:0] c_ts

);
    RS_ENTRY [`RS_SZ-1:0]       entries, entries_n;
    logic    [$clog2(`RS_SZ):0] rs_cnt;

    logic [`RS_SZ-1:0] busy_vec;
    logic [`RS_SZ-1:0] issd_vec;
    logic [`RS_SZ-1:0] t1_rdy_vec;
    logic [`RS_SZ-1:0] t2_rdy_vec;
    generate
    for (genvar i = 0; i < `RS_SZ; i++) begin : gen_vecs
        assign busy_vec[i] = entries[i].busy;
        assign issd_vec[i] = entries[i].issued;
        assign t1_rdy_vec[i] = entries[i].dat.t1_rdy;
        assign t2_rdy_vec[i] = entries[i].dat.t2_rdy;
    end
    endgenerate

    // cdb completion
    logic [`RS_SZ-1:0] to_t1_rdy;
    logic [`RS_SZ-1:0] to_t2_rdy;
    always_comb begin
        to_t1_rdy = t1_rdy_vec;
        to_t2_rdy = t2_rdy_vec;
        for (int i = 0; i < `RS_SZ; ++i) begin
            for (int j = 0; j < `N; ++j) begin
                if (!c_en[j])
                    continue;
                to_t1_rdy[i] |= entries[i].dat.t1 == c_ts[j];
                to_t2_rdy[i] |= entries[i].dat.t2 == c_ts[j];
            end
        end
    end

    // issue
    logic [`RS_SZ-1:0] to_issue;
    logic can_issue;
    always_comb begin
        logic [$clog2(`N):0][`FU_IDX_NUM-1:0] fu_scnts = fu_scnt;
        s_vld = '0;
        to_issue = '0;

        for (int i = 0, int cnt = 0; i < `RS_SZ; ++i) begin
            // issued up to width
            if (cnt >= `N)
                break;

            // not ready to issue
            can_issue = busy_vec[i]
                && fu_scnts[entries[i].dat.fu_idx] > 0
                && (entries[i].dat.t1_rdy || to_t1_rdy[i])
                && (entries[i].dat.t2_rdy || to_t2_rdy[i]);

            if (!can_issue)
                continue;

            to_issue[i] = 1;
            s_vld[cnt]  = 1;
            s_dat[cnt]  = entries[i].dat;
            --fu_scnts[entries[i].dat.fu_idx];
            ++cnt;
        end
    end

    // compute free entries
    logic [`RS_SZ-1:0] free_entries;
    assign free_entries = 
        ~busy_vec
        | issd_vec; // an issued insn will go to EX and free its entry
    assign rs_cnt = $countones(free_entries);
    assign rs_scnt = rs_cnt > `N ? `N : rs_cnt;


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
            if (!d_vld[i])
                continue;
            d_gnt_bus[i] |= free_gnt_bus[i];
        end
    end


    always_comb begin
        entries_n = entries;
        for (int i = 0; i < `RS_SZ; ++i) begin
            entries_n[i].dat.t1_rdy |= to_t1_rdy[i];
            entries_n[i].dat.t2_rdy |= to_t2_rdy[i];

            if (to_issue[i]) begin
                entries_n[i].issued = 1;
                continue;
            end

            for (int j = 0; j < `N; ++j) begin
                if (!d_gnt_bus[i][j])
                    continue;
                entries_n[i].busy   = 1;
                entries_n[i].issued = 0;
                entries_n[i].dat    = d_dat[j];
                break;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            entries <= '0;
        end else begin
            entries <= entries_n;
        end
    end


endmodule