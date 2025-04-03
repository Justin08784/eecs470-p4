`include "sys_defs.svh"

/*
TODO:
- Do w->r forwarding optimization tricks like those you used in fifo/rob?
(in particular, combinationally updating entries_n seems incredibly expensive.
What if we handle all writes synchronously? And combinationally forward writes to
reads.)
- Bundle rs I/O by stages like rob and free_list?
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
    rs_rdy_scnt saturates at N (Why? A: even if we have more free RS entries 
    than N, we can only dispatch at most N each cycle anyways).

    e.g. N = 2
    logic [1:0] rs_rdy_scnt;
    b00 +> b01 +> b10 (cannot increment further)
    0      1      2 
    */
    output  rs2dispatch     d_out,
    input   dispatch2rs     d_in,

    // issue
    input   execute2rs                      ex_in,
    output  rs2execute                      ex_out,


    `ifdef DEBUG
    output  RS_ENTRY    [RS_SZ-1:0]       entries_dbg,
    `endif 

    // complete (CDB)
    input execute2complete  c_in
);
    RS_ENTRY [RS_SZ-1:0]       entries; // ms1 test: remove one RS entry (caught)
    `ifdef DEBUG
    assign entries_dbg = entries;
    `endif 

    logic [RS_SZ-1:0] busy_vec;
    logic [RS_SZ-1:0] issd_vec;
    logic [RS_SZ-1:0] t1_rdy_vec;
    logic [RS_SZ-1:0] t2_rdy_vec;
    generate
    for (genvar i = 0; i < RS_SZ; i++) begin : gen_vecs // ms1 test: make loop count RS_SZ-1 instead of RS_SZ (caught)
        assign busy_vec[i] = entries[i].busy; // ms1 test: make busy_vec sequential instead of combinational (caught)
        assign issd_vec[i] = entries[i].issued;
        assign t1_rdy_vec[i] = entries[i].dat.t1_rdy;
        assign t2_rdy_vec[i] = entries[i].dat.t2_rdy;
    end
    endgenerate

    // SECTION: cdb completion
    logic [`N-1:0][RS_SZ-1:0] to_t1_rdy_per_cpl;
    logic [`N-1:0][RS_SZ-1:0] to_t2_rdy_per_cpl;
    logic [RS_SZ-1:0] to_t1_rdy;
    logic [RS_SZ-1:0] to_t2_rdy;
    always_comb begin
        to_t1_rdy_per_cpl = '0;
        to_t2_rdy_per_cpl = '0;
        foreach(to_t1_rdy_per_cpl[n, rs]) begin
            if (!c_in.c_en[n])
                continue;
            to_t1_rdy_per_cpl[n][rs] = entries[rs].dat.t1 == c_in.c_ts[n];
            to_t2_rdy_per_cpl[n][rs] = entries[rs].dat.t2 == c_in.c_ts[n];
        end

        to_t1_rdy = '0;
        to_t2_rdy = '0;
        foreach(to_t1_rdy_per_cpl[n, rs]) begin
            to_t1_rdy[rs] |= to_t1_rdy_per_cpl[n][rs];
            to_t2_rdy[rs] |= to_t2_rdy_per_cpl[n][rs];
        end
    end

    // SECTION: Issue 
    // operand readiness
    logic [RS_SZ-1:0] can_issue;                   
    // operand readiness per FU type
    logic [FU_IDX_NUM-1:0][RS_SZ-1:0] can_issues;
    always_comb begin
        can_issues = '0;
        for (int rs = 0, FU_IDX fu = 0; rs < RS_SZ; ++rs) begin
            can_issue[rs] = busy_vec[rs]
                && !entries[rs].issued // ms1 test: remove "!" from entries[rs].issued (caught)
                && (entries[rs].dat.t1_rdy || to_t1_rdy[rs]) // [ADDRESSED] ms1 test: remove "|| to_t1_rdy[rs]" (not caught) 
                && (entries[rs].dat.t2_rdy || to_t2_rdy[rs]);

            fu = entries[rs].dat.fu_idx;
            can_issues[fu][rs] = can_issue[rs];
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
        .req    (ex_in.fu_rdy_alu),
        .gnt_bus(gbus_fu_rdy_alu)
    );
    psel_gen #(
        .WIDTH  (NUM_FU_MULT),
        .REQS   (NUM_FU_MULT)
    ) sel_rdy_mult (
        .req    (ex_in.fu_rdy_mult),
        .gnt_bus(gbus_fu_rdy_mult)
    );
    psel_gen #(
        .WIDTH  (NUM_FU_LOAD),
        .REQS   (NUM_FU_LOAD)
    ) sel_rdy_load (
        .req    (ex_in.fu_rdy_load),
        .gnt_bus(gbus_fu_rdy_load)
    );     
    psel_gen #(
        .WIDTH  (NUM_FU_STORE),
        .REQS   (NUM_FU_STORE)
    ) sel_rdy_store (
        .req    (ex_in.fu_rdy_store),
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
        ex_out.fu_vld_alu      = '0;
        ex_out.fu_vld_mult     = '0;
        ex_out.fu_vld_store    = '0;
        ex_out.fu_vld_load     = '0;

        foreach (gbus_fu_rdy_alu[i, j]) begin
            if (gbus_fu_rdy_alu[i][j]) begin
                fu2issuer_alu[j]    |= gbus_can_issue_alu[i];
                /*
                This feels expensive. Isn't there a more efficient way to check
                if a gnt_bus row is actually used?
                \/ \/ \/ \/
                */
                ex_out.fu_vld_alu[j]       = |gbus_can_issue_alu[i];
                // for (int rs = 0; rs < RS_SZ; ++rs) begin
                //     ex_out.fu_dat_alu[j]   |= entries[i];
                // end
                to_issue            |= gbus_can_issue_alu[i];
            end
        end
        foreach (gbus_fu_rdy_mult[i, j]) begin
            if (gbus_fu_rdy_mult[i][j]) begin
                fu2issuer_mult[j]   |= gbus_can_issue_mult[i];
                ex_out.fu_vld_mult[j]      = |gbus_can_issue_mult[i]; // [MISSING] ms1 test: change i to j (not caught)
                to_issue            |= gbus_can_issue_mult[i];
            end
        end
        foreach (gbus_fu_rdy_load[i, j]) begin
            if (gbus_fu_rdy_load[i][j]) begin
                fu2issuer_load[j]   |= gbus_can_issue_load[i];
                ex_out.fu_vld_load[j]      = |gbus_can_issue_load[i];
                to_issue            |= gbus_can_issue_load[i];

            end
        end
        foreach (gbus_fu_rdy_store[i, j]) begin
            if (gbus_fu_rdy_store[i][j]) begin
                fu2issuer_store[j]  |= gbus_can_issue_store[i];
                ex_out.fu_vld_store[j]     = |gbus_can_issue_store[i];
                to_issue            |= gbus_can_issue_store[i];
            end
        end
    end

    function automatic BYPASS_TAG get_bytag (
        input int rs
    );
        BYPASS_TAG tag = '0;
        for (int n = 0; n < N; ++n) begin
            if (to_t1_rdy_per_cpl[n][rs]) begin
                tag.bypass1     |= 1; // TODO: What about zero reg? A matching zero reg should not count as a valid wakeup!
                tag.cdb_idx1    |= n; // This should be okay. Two insns cannot have the same destination tag! There is a $fatal check for this in execute.sv
            end
            if (to_t2_rdy_per_cpl[n][rs]) begin
                tag.bypass2     |= 1;
                tag.cdb_idx2    |= n;
            end
        end
        return tag;
    endfunction

    always_comb begin
        ex_out.fu_dat_alu   = '0;
        ex_out.fu_dat_mult  = '0;
        ex_out.fu_dat_store = '0;
        ex_out.fu_dat_load  = '0;
        ex_out.bytag_alu    = '0; // TODO: set
        ex_out.bytag_mul    = '0; // TODO: set
        ex_out.bytag_ldr    = '0; // TODO: set
        ex_out.bytag_str    = '0; // TODO: set
        foreach (fu2issuer_alu[fu, rs]) begin
            if (fu2issuer_alu[fu][rs]) begin // [MISSING] ms1 test: Remove "!" from if condition (not caught)
                ex_out.fu_dat_alu[fu] |= entries[rs].dat;
                ex_out.bytag_alu[fu]  |= get_bytag(rs);
            end
        end
        foreach (fu2issuer_mult[fu, rs]) begin
            if (fu2issuer_mult[fu][rs]) begin
                ex_out.fu_dat_mult[fu] |= entries[rs].dat;
                ex_out.bytag_mul[fu]   |= get_bytag(rs);
            end
        end
        foreach (fu2issuer_load[fu, rs]) begin
            if (fu2issuer_load[fu][rs]) begin
                ex_out.fu_dat_load[fu] |= entries[rs].dat;
                ex_out.bytag_ldr[fu]   |= get_bytag(rs);
            end
        end
        foreach (fu2issuer_store[fu, rs]) begin
            if (fu2issuer_store[fu][rs]) begin
                ex_out.fu_dat_store[fu] |= entries[rs].dat;
                ex_out.bytag_str[fu]    |= get_bytag(rs);
            end
        end
    end

    // SECTION: Dispatch
    // compute free entries
    logic [RS_SZ-1:0] free_entries;
    assign free_entries = 
        ~busy_vec
        | issd_vec; // an issued insn will go to EX and free its entry

    // select free entries
    logic [N-1:0][RS_SZ-1:0] gbus_free;
    psel_gen #(
        .WIDTH(RS_SZ),
        .REQS(N)
    ) sel_free_entries (
        .req    (free_entries),
        .gnt_bus(gbus_free)
    );

    logic [N-1:0][RS_SZ-1:0] d2entry;
    always_comb begin
        d2entry = '0;
        foreach (d2entry[i]) begin
            if (i < d_in.d_en_cnt) begin
                d2entry[i] |= gbus_free[i];
            end
        end
        d_out.rs_rdy_scnt = $countones({|gbus_free[0], |gbus_free[1]});
    end


    `ifndef SYNTH
    function get_fu_name(input FU_IDX fu_idx, output string name);
        case (fu_idx)
            FU_ALU:     name = "ALU";
            FU_MULT:    name = "MULT";
            FU_LOAD:    name = "LOAD";
            FU_STORE:   name = "STORE";
            default:    name = "Unknown FU";
        endcase
    endfunction
    `endif

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            entries  <= '0;
        end else begin
            // SECTION: Compute next state
            for (int rs = 0; rs < RS_SZ; ++rs) begin
                entries[rs].dat.t1_rdy <= entries[rs].dat.t1_rdy | to_t1_rdy[rs];
                entries[rs].dat.t2_rdy <= entries[rs].dat.t2_rdy | to_t2_rdy[rs]; // [ADDRESSED] ms1 test: change |= to = (not caught)
                /*
                TODO: Ask Bradley! This change is not breaking because t2_rdy is 
                ALREADY incorporated into the value of to_t2_rdy, which means an
                assignment behaves identically to 'or' assignment here. i.e. logically redundant
                This is because to_t2_rdy is initialized to t2_rdy, instead of 0;
                if we did the latter, it would break as intended. So can we get
                our points back here? */

                // issuing
                if (to_issue[rs])
                    entries[rs].issued <= 1;

                // going to EX; clear entry
                if (entries[rs].issued)
                    entries[rs].busy <= 0; // only clear busy bit

                for (int n = 0; n < N; ++n) begin
                    if (!d2entry[n][rs])
                        continue;
                    entries[rs].busy   <= 1;
                    entries[rs].issued <= 0;
                    entries[rs].dat    <= d_in.d_dat[n];
                end
            end

        end

        `ifdef DEBUG
        if (!reset) begin
            $display("  %3d | >> RS >>", $time);
            print_id_result(d_in.d_dat[0]);
            print_id_result(d_in.d_dat[1]);
            for (int i = 0; i < RS_SZ; ++i) begin
                string fu_name;
                get_fu_name(entries[i].dat.fu_idx, fu_name);

                if (!entries[i].busy) begin
                    $display("Entry [%2d]:", i);
                    continue;
                end

                $display("Entry [%2d]: pc=0x%x, id=%3d (%x), busy=%b, issued=%b, t=%2d, t1=%2d, t2=%2d, t1_rdy=%b, t2_rdy=%b, fu=%s(%2d)",
                    i, 
                    entries[i].dat.PC,
                    entries[i].dat.id, 
                    entries[i].dat.inst,
                    entries[i].busy, 
                    entries[i].issued, 
                    entries[i].dat.t, 
                    entries[i].dat.t1, 
                    entries[i].dat.t2, 
                    entries[i].dat.t1_rdy, 
                    entries[i].dat.t2_rdy, 
                    
                    entries[i].busy ? fu_name : "*",
                    entries[i].dat.fu_idx,
                );
            end
            $display("  %3d | << RS <<", $time);
        end
        `endif
    end


endmodule