

`include "sys_defs.svh"


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

module rs #(parameter 
    N=`N,
    RS_SZ=`RS_SZ,
    FU_IDX_NUM=`FU_IDX_NUM,
    NUM_FU_ALU=`NUM_FU_ALU,
    NUM_FU_MULT=`NUM_FU_MULT,
    NUM_FU_LOAD=`NUM_FU_LOAD,
    NUM_FU_STORE=`NUM_FU_STORE
) (
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

    Questions: 
    - 1. Is it better to directly expose the RS to the dispatcher and have it
    assign directly to the entries array?
    - 2. In general, maybe we should ferry around buses instead of saturating
    counts so we can do direct assignment without additional combo logic to
    decode the counts etc.
    - 3. Only the CDB has to be width N. I believe EVERYTHING ELSE (including
    fetch, dispatch, issue, writeback) can do ARBITRARILIY MANY ops.
    */
    output  logic           [$clog2(N):0] rs_scnt, // to dispatcher
    input   logic           [N-1:0] d_vld,     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    input   ID_RESULT       [N-1:0] d_dat,
    /* CONCERN 1:
    What data do we actually need to store in the RS so that it can immediately
    execute after issue to an FU? Like I'm looking at the fields of ID_EX_PACKET
    and they are considerable?
    */

    // issue
    input   logic       [NUM_FU_ALU-1:0]    fu_rdy_alu,
    input   logic       [NUM_FU_MULT-1:0]   fu_rdy_mult,
    input   logic       [NUM_FU_STORE-1:0]  fu_rdy_store,
    input   logic       [NUM_FU_LOAD-1:0]   fu_rdy_load,

    output  logic       [NUM_FU_ALU-1:0]    fu_vld_alu,
    output  logic       [NUM_FU_MULT-1:0]   fu_vld_mult,
    output  logic       [NUM_FU_STORE-1:0]  fu_vld_store,
    output  logic       [NUM_FU_LOAD-1:0]   fu_vld_load,
    output  ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu,
    output  ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult,
    output  ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store,
    output  ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load,
    /* Ditto CONCERN 1 */

    // complete (CDB)
    /*
    Mustafa:
    implement backpressure from the CDB (one of tips in slides apparently?)
    (make a rdy-vld handshake between FUs and reservation stations)
    */
    input   logic           [N-1:0] c_en,
    input   PHYS_REG_IDX    [N-1:0] c_ts

);
    RS_ENTRY [RS_SZ-1:0]       entries, entries_n;

    logic [RS_SZ-1:0] busy_vec;
    logic [RS_SZ-1:0] issd_vec;
    logic [RS_SZ-1:0] t1_rdy_vec;
    logic [RS_SZ-1:0] t2_rdy_vec;
    generate
    for (genvar i = 0; i < RS_SZ; i++) begin : gen_vecs
        assign busy_vec[i] = entries[i].busy;
        assign issd_vec[i] = entries[i].issued;
        assign t1_rdy_vec[i] = entries[i].dat.t1_rdy;
        assign t2_rdy_vec[i] = entries[i].dat.t2_rdy;
    end
    endgenerate

    // SECTION: cdb completion
    /* Potential optimization:
    Keep a "scoreboard" of physical register ready statuses i.e.
    logic [PHYS_REG_IDX-1:0] preg_rdy;
    ...then have each RS entry index their source tags in this preg_rdy table
    every cycle to check for readiness. (But isn't this just the map
    table / architectural map? confused...)
    Bradley said this could have lower complexity than the current approach
    (but it seems more complicated).
    */
    logic [RS_SZ-1:0] to_t1_rdy;
    logic [RS_SZ-1:0] to_t2_rdy;
    always_comb begin
        to_t1_rdy = '0;
        to_t2_rdy = '0;
        for (int rs = 0; rs < RS_SZ; ++rs) begin
            logic match_t1;
            logic match_t2;
            match_t1 = t1_rdy_vec[rs];
            match_t2 = t2_rdy_vec[rs];

            // match any tag in CDB?
            for (int n = 0; n < N; ++n) begin
                if (c_en[n]) begin
                    match_t1 |= entries[rs].dat.t1 == c_ts[n];
                    match_t2 |= entries[rs].dat.t2 == c_ts[n];
                end
            end

            to_t1_rdy[rs] = match_t1;
            to_t2_rdy[rs] = match_t2;
        end
    end

    // SECTION: Issue 
    // operand readiness
    logic [RS_SZ-1:0] can_issue;                   
    // operand readiness per FU type
    logic [FU_IDX_NUM-1:0][RS_SZ-1:0] can_issues;
    always_comb begin
        can_issues = '0;
        for (int rs = 0; rs < RS_SZ; ++rs) begin
            can_issue[rs] = busy_vec[rs]
                && !entries[rs].issued
                && (entries[rs].dat.t1_rdy || to_t1_rdy[rs])
                && (entries[rs].dat.t2_rdy || to_t2_rdy[rs]);

            can_issues[entries[rs].dat.fu_idx][rs] = can_issue[rs];
        end
    end

    // select issue lines per FU type
    logic [NUM_FU_ALU-1:0]  [RS_SZ-1:0] gbus_can_issue_alu; // gbus = grant bus
    logic [NUM_FU_MULT-1:0] [RS_SZ-1:0] gbus_can_issue_mult;
    logic [NUM_FU_LOAD-1:0] [RS_SZ-1:0] gbus_can_issue_load;
    logic [NUM_FU_STORE-1:0][RS_SZ-1:0] gbus_can_issue_store;
    psel_gen #(
        .WIDTH  (RS_SZ),
        .REQS   (NUM_FU_ALU)
    ) sel_iss_alu (
        .req    (can_issues[FU_ALU]),
        .gnt_bus(gbus_can_issue_alu)
    );
    psel_gen #(
        .WIDTH  (RS_SZ),
        .REQS   (NUM_FU_MULT)
    ) sel_iss_mult (
        .req    (can_issues[FU_MULT]),
        .gnt_bus(gbus_can_issue_mult)
    );
    psel_gen #(
        .WIDTH  (RS_SZ),
        .REQS   (NUM_FU_LOAD)
    ) sel_iss_load (
        .req    (can_issues[FU_LOAD]),
        .gnt_bus(gbus_can_issue_load)
    );
    psel_gen #(
        .WIDTH  (RS_SZ),
        .REQS   (NUM_FU_STORE)
    ) sel_iss_store (
        .req    (can_issues[FU_STORE]),
        .gnt_bus(gbus_can_issue_store)
    );

    // select available FUs
    logic [NUM_FU_ALU-1:0]  [NUM_FU_ALU-1:0]    gbus_fu_rdy_alu;
    logic [NUM_FU_MULT-1:0] [NUM_FU_MULT-1:0]   gbus_fu_rdy_mult;
    logic [NUM_FU_LOAD-1:0] [NUM_FU_LOAD-1:0]   gbus_fu_rdy_load;
    logic [NUM_FU_STORE-1:0][NUM_FU_STORE-1:0]  gbus_fu_rdy_store;
    psel_gen #(
        .WIDTH  (NUM_FU_ALU),
        .REQS   (NUM_FU_ALU)
    ) sel_rdy_alu (
        .req    (fu_rdy_alu),
        .gnt_bus(gbus_fu_rdy_alu)
    );
    psel_gen #(
        .WIDTH  (NUM_FU_MULT),
        .REQS   (NUM_FU_MULT)
    ) sel_rdy_mult (
        .req    (fu_rdy_mult),
        .gnt_bus(gbus_fu_rdy_mult)
    );
    psel_gen #(
        .WIDTH  (NUM_FU_LOAD),
        .REQS   (NUM_FU_LOAD)
    ) sel_rdy_load (
        .req    (fu_rdy_load),
        .gnt_bus(gbus_fu_rdy_load)
    );     
    psel_gen #(
        .WIDTH  (NUM_FU_STORE),
        .REQS   (NUM_FU_STORE)
    ) sel_rdy_store (
        .req    (fu_rdy_store),
        .gnt_bus(gbus_fu_rdy_store)
    );

    // assign FUs to issuables
    logic [RS_SZ-1:0] to_issue;
    logic [NUM_FU_ALU-1:0]  [RS_SZ-1:0] fu2issuer_alu;
    logic [NUM_FU_MULT-1:0] [RS_SZ-1:0] fu2issuer_mult;
    logic [NUM_FU_LOAD-1:0] [RS_SZ-1:0] fu2issuer_load;
    logic [NUM_FU_STORE-1:0][RS_SZ-1:0] fu2issuer_store;

    always_comb begin
        to_issue        = '0;
        fu2issuer_alu   = '0;
        fu2issuer_mult  = '0;
        fu2issuer_load  = '0;
        fu2issuer_store = '0;
        fu_vld_alu      = '0;
        fu_vld_mult     = '0;
        fu_vld_store    = '0;
        fu_vld_load     = '0;
        // fu_dat_alu      = '0;
        // fu_dat_mult     = '0;
        // fu_dat_store    = '0;
        // fu_dat_load     = '0;

        foreach (gbus_fu_rdy_alu[i, j]) begin
            if (gbus_fu_rdy_alu[i][j]) begin
                fu2issuer_alu[j]    |= gbus_can_issue_alu[i];
                /*
                This feels expensive. Isn't there a more efficient way to check
                if a gnt_bus row is actually used?
                \/ \/ \/ \/
                */
                fu_vld_alu[j]       = |gbus_can_issue_alu[i];
                // for (int rs = 0; rs < RS_SZ; ++rs) begin
                //     fu_dat_alu[j]   |= entries[i];
                // end
                to_issue            |= gbus_can_issue_alu[i];
            end
        end
        foreach (gbus_fu_rdy_mult[i, j]) begin
            if (gbus_fu_rdy_mult[i][j]) begin
                fu2issuer_mult[j]   |= gbus_can_issue_mult[i];
                fu_vld_mult[j]      = |gbus_can_issue_mult[i];
                to_issue            |= gbus_can_issue_mult[i];
            end
        end
        foreach (gbus_fu_rdy_load[i, j]) begin
            if (gbus_fu_rdy_load[i][j]) begin
                fu2issuer_load[j]   |= gbus_can_issue_load[i];
                fu_vld_load[j]      = |gbus_can_issue_load[i];
                to_issue            |= gbus_can_issue_load[i];

            end
        end
        foreach (gbus_fu_rdy_store[i, j]) begin
            if (gbus_fu_rdy_store[i][j]) begin
                fu2issuer_store[j]  |= gbus_can_issue_store[i];
                fu_vld_store[j]     = |gbus_can_issue_store[i];
                to_issue            |= gbus_can_issue_store[i];
            end
        end
        /*
        TODO: We're not actually doing anything fu2issuer_Xs?
        Should we not set fu_dat_Xs? */
    end

    /*
    TODO: 
    - 1. THERE IS NO ISSUE LIMIT (i.e. you can issue as many FUs as there
    are available and instructions with operands ready). i.e. the 2nd level
    psel_gen is no longer necessary!
    - 2. Expose the FU array DIRECTLY to the rs module and allow rs to DIRECTLY
    ASSIGN new issues to FUs (dont mess around with fu_scnt crap)
    */


    // SECTION: Dispatch
    // compute free entries
    logic [$clog2(RS_SZ):0] rs_cnt;
    logic [RS_SZ-1:0] free_entries;
    assign free_entries = 
        ~busy_vec
        | issd_vec; // an issued insn will go to EX and free its entry
    assign rs_cnt = $countones(free_entries);
    assign rs_scnt = rs_cnt > N ? N : rs_cnt;


    // select free entries
    /*
    NOTE: The second psel, sel_d_vld, is not necessary if we assume dispatches
    will compactly fill from the lowest indices. However, I am too lazy to
    remember that when crafting tests. In addition, we will move this dispatch
    logic to the dispatcher module which shall directly assign dispatches to
    RS entries without this compressed intermediate d_vld, d_dat line crap.
    */
    logic [N-1:0][RS_SZ-1:0] gbus_free;
    psel_gen #(
        .WIDTH(RS_SZ),
        .REQS(N)
    ) sel_free_entries (
        .req    (free_entries),
        .gnt_bus(gbus_free)
    );

    // select valid dispatches
    logic [N-1:0][N-1:0] gbus_d_vld;
    psel_gen #(
        .WIDTH(N),
        .REQS(N)
    ) sel_d_vld (
        .req    (d_vld),
        .gnt_bus(gbus_d_vld)
        // .empty()
    );

    logic [N-1:0][RS_SZ-1:0] d2entry;
    always_comb begin
        d2entry = '0;
        foreach (gbus_d_vld[i, j]) begin
            if (gbus_d_vld[i][j]) begin
                d2entry[j] |= gbus_free[i];
                // to_issue   |= gbus_can_issue_alu[i];
            end
        end
    end

    /*
    Mustafa:
    if you make it alternating it might dispatch younger insns
    so just make it a dependent for-loop (i.e. serial); it shouldnt
    be too big of a deal. But possible room for optimization 
    by making it a lowest-index first priority encoder?
    */

    // SECTION: Compute next state
    always_comb begin
        entries_n = entries;
        for (int rs = 0; rs < RS_SZ; ++rs) begin
            entries_n[rs].dat.t1_rdy |= to_t1_rdy[rs];
            entries_n[rs].dat.t2_rdy |= to_t2_rdy[rs];

            if (to_issue[rs]) begin
                // issuing
                entries_n[rs].issued = 1;
                continue;
            end

            if (entries_n[rs].issued) begin
                // going to EX; clear entry
                entries_n[rs] = '0; // optimize later: only clear busy bit
            end

            for (int n = 0; n < N; ++n) begin
                if (!d2entry[n][rs])
                    continue;
                entries_n[rs].busy   = 1;
                entries_n[rs].issued = 0;
                entries_n[rs].dat    = d_dat[n];

                // this break should not be necessary if psel_gen guarantees at most 1 per row
                // adding it may confuse compiler into making it dependent too...
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