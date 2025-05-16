`include "sys_defs.svh"

typedef struct packed {
    PHYS_REG_IDX t1;
    PHYS_REG_IDX t2;
    logic t1_rdy;
    logic t2_rdy;
} _RS_PAYLOAD_STUB;
typedef struct packed {
    logic busy;
    logic issd;
    _RS_PAYLOAD_STUB dat;
} _RS_ENTRY_STUB;

typedef struct packed {
    logic busy;
    logic issd;
    RS_ALU_PAYLOAD dat;
} RS_ALU_ENTRY;
typedef struct packed {
    logic busy;
    logic issd;
    RS_MUL_PAYLOAD dat;
} RS_MULT_ENTRY;
typedef struct packed {
    logic busy;
    logic issd;
    RS_BRU_PAYLOAD dat;
} RS_BRU_ENTRY;

/*
* Generic RS partition
* */
module rs_part #(
    type PAYLOAD=_RS_PAYLOAD_STUB,
    type ENTRY  =_RS_ENTRY_STUB,
    parameter   FU=FU_ALU,
    parameter   N=`N,
    parameter   PART_SZ=1,
    parameter   NUM_FU=1,
    parameter   ISS_CDB_ARB=`FALSE
) (
    input clock,
    input reset,
    input flush,

    // dispatch
    input  logic    [N-1:0]     d_in_en,
    input  PAYLOAD  [N-1:0]     d_in_dat,

    output logic    [N-1:0]     d_out_rdy_sbus,

    // issue
    input  logic   [NUM_FU-1:0] ex_in_fu_rdy,

    // logic   [NUM_FU-1:0]    cdb_gnt;
    input  logic   [NUM_FU-1:0] ex_in_fu_cdb_gnt, // 1-cycle insns need to win CDB arb. to issue

    /* Requested by issue arbiter
    (only ALU/BRCH needs gnt by CDB arbiter to 'en')*/
    // logic   [NUM_FU-1:0]    iss_vld;
    output logic   [NUM_FU-1:0] ex_out_fu_vld,

    /* Selected for issue */
    // logic   [NUM_FU-1:0]    iss_en;
    // ENTRY   [NUM_FU-1:0]    iss_dat;
    output logic   [NUM_FU-1:0] ex_out_fu_en,
    output PAYLOAD [NUM_FU-1:0] ex_out_fu_dat,
    output BYPASS_TAG [NUM_FU-1:0] ex_out_bytag,
    /*
    * NOTE: causally, fu_rdy -> iss_vld -> cdb_gnt -> iss_en, iss_dat
    * */

    // complete (CDB)
    input execute2complete_tag  ctag_in
);
    ENTRY [PART_SZ-1:0] entries; // ms1 test: remove one RS entry (caught)

    logic [PART_SZ-1:0] busy_vec;
    logic [PART_SZ-1:0] issd_vec;
    logic [PART_SZ-1:0] t1_rdy_vec;
    logic [PART_SZ-1:0] t2_rdy_vec;
    generate
    for (genvar i = 0; i < PART_SZ; i++) begin : gen_vecs // ms1 test: make loop count PART_SZ-1 instead of PART_SZ (caught)
        assign busy_vec[i] = entries[i].busy; // ms1 test: make busy_vec sequential instead of combinational (caught)
        assign issd_vec[i] = entries[i].issd;
        assign t1_rdy_vec[i] = entries[i].dat.t1_rdy;
        assign t2_rdy_vec[i] = entries[i].dat.t2_rdy;
    end
    endgenerate

    // SECTION: cdb completion
    logic [`N-1:0][PART_SZ-1:0] to_t1_rdy_per_cpl;
    logic [`N-1:0][PART_SZ-1:0] to_t2_rdy_per_cpl;
    logic [PART_SZ-1:0] to_t1_rdy;
    logic [PART_SZ-1:0] to_t2_rdy;
    always_comb begin
        to_t1_rdy_per_cpl = '0;
        to_t2_rdy_per_cpl = '0;
        foreach(to_t1_rdy_per_cpl[n, rs]) begin
            if (!ctag_in.en[n])
                continue;
            to_t1_rdy_per_cpl[n][rs] = entries[rs].dat.t1 == ctag_in.ts[n]
                && ctag_in.ts[n] != '0;
            to_t2_rdy_per_cpl[n][rs] = entries[rs].dat.t2 == ctag_in.ts[n]
                && ctag_in.ts[n] != '0;
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
    logic [PART_SZ-1:0] can_issue;
    always_comb begin
        can_issue = '0;
        for (int rs = 0; rs < PART_SZ; ++rs) begin
            can_issue[rs] = busy_vec[rs]
                && !entries[rs].issd // ms1 test: remove "!" from entries[rs].issd (caught)
                && (entries[rs].dat.t1_rdy || to_t1_rdy[rs]) // [ADDRESSED] ms1 test: remove "|| to_t1_rdy[rs]" (not caught) 
                && (entries[rs].dat.t2_rdy || to_t2_rdy[rs]);
        end
    end

    // select issue lines
    logic [NUM_FU-1:0][PART_SZ-1:0] gbus_can_issue;
    psel_gen #(
        .WIDTH  (PART_SZ),
        .REQS   (NUM_FU)
    ) sel_iss (
        .req    (can_issue),
        .gnt_bus(gbus_can_issue)
    );

    // select available FUs
    logic [NUM_FU-1:0][NUM_FU-1:0]  gbus_fu_rdy;
    psel_gen #(
        .WIDTH  (NUM_FU),
        .REQS   (NUM_FU)
    ) sel_rdy_alu (
        .req    (ex_in_fu_rdy),
        .gnt_bus(gbus_fu_rdy)
    );


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

    // assign FUs to issuables
    logic [PART_SZ-1:0] to_issue;
    logic [NUM_FU-1:0][PART_SZ-1:0] fu2issuer;

    always_comb begin
        to_issue    = '0;
        fu2issuer   = '0;
        ex_out_fu_vld   = '0;
        ex_out_fu_en    = '0;

        foreach (gbus_fu_rdy[i, j]) begin
            if (gbus_fu_rdy[i][j]) begin
                fu2issuer[j]    |= gbus_can_issue[i];

                if (ISS_CDB_ARB) begin
                    ex_out_fu_vld[j]    = |gbus_can_issue[i];
                    /* WARNING: There is an entire CDB arbitration between these two lines...
                    ALU insns can only issue if they ALSO win (early) CDB arbitration! */
                    ex_out_fu_en[j]     = ex_out_fu_vld[j] && ex_in_fu_cdb_gnt[j];
                    to_issue            |= ex_in_fu_cdb_gnt[j] ? gbus_can_issue[i] : '0;
                end else begin
                    ex_out_fu_en[j]     = |gbus_can_issue[i];
                    to_issue            |= gbus_can_issue[i];
                end
            end
        end
    end

    always_comb begin
        ex_out_fu_dat   = '0;
        ex_out_bytag    = '0;
        foreach (fu2issuer[fu, rs]) begin
            if (fu2issuer[fu][rs]) begin // [MISSING] ms1 test: Remove "!" from if condition (not caught)
                ex_out_fu_dat[fu] |= entries[rs].dat;
                ex_out_bytag[fu]  |= get_bytag(rs);
            end
        end
    end

    // SECTION: Dispatch
    // compute free entries
    logic [PART_SZ-1:0] free_entries;
    assign free_entries = 
        ~busy_vec
        | issd_vec; // an issued insn will go to EX and free its entry

    // select free entries
    logic [N-1:0][PART_SZ-1:0] gbus_free;
    psel_gen #(
        .WIDTH(PART_SZ),
        .REQS(N)
    ) sel_free_entries (
        .req    (free_entries),
        .gnt_bus(gbus_free)
    );

    logic [N-1:0][PART_SZ-1:0] d2entry;
    always_comb begin
        d2entry = '0;
        foreach (d2entry[i]) begin
            if (d_in_en[i]) begin
                d2entry[i] |= gbus_free[i];
            end
        end

        foreach (gbus_free[n])
            d_out_rdy_sbus[n] = |gbus_free[n];
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            entries  <= '0;
        end else begin
            // SECTION: Compute next state
            for (int rs = 0; rs < PART_SZ; ++rs) begin
                entries[rs].dat.t1_rdy <= entries[rs].dat.t1_rdy | to_t1_rdy[rs];
                entries[rs].dat.t2_rdy <= entries[rs].dat.t2_rdy | to_t2_rdy[rs]; // [ADDRESSED] ms1 test: change |= to = (not caught)

                // issuing
                if (to_issue[rs])
                    entries[rs].issd <= 1;

                // going to EX; clear entry
                if (entries[rs].issd)
                    entries[rs].busy <= 0; // only clear busy bit

                for (int n = 0; n < N; ++n) begin
                    if (!d2entry[n][rs])
                        continue;
                    entries[rs].busy    <= 1;
                    entries[rs].issd    <= 0;
                    entries[rs].dat     <= d_in_dat[n];
                end
            end

        end
    end
endmodule;


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
    FU_IDX_NUM=`FU_IDX_NUM,
    NUM_FU_ALU=`NUM_FU_ALU,
    NUM_FU_MUL=`NUM_FU_MUL,
    NUM_FU_LOD=`NUM_FU_LOD,
    NUM_FU_STR=`NUM_FU_STR
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
    input  dispatch2rs  d_in,
    output rs2dispatch  d_out,

    // issue
    input  execute2rs   ex_in,
    output rs2execute   ex_out,

    // complete (CDB)
    input execute2complete_tag  ctag_in
);
    RS_ALU_PAYLOAD [`N-1:0] tmp_dat_alu;
    always_comb begin
        foreach (d_in.dat[i]) begin
            tmp_dat_alu[i] = '{
`ifdef DEBUG
                id          : d_in.dat[i].id,
`endif
                bmask       : d_in.dat[i].bmask,

                PC          : d_in.dat[i].PC,
                inst        : d_in.dat[i].inst,

                t           : d_in.dat[i].t,
                t1          : d_in.dat[i].t1,
                t2          : d_in.dat[i].t2,
                t1_rdy      : d_in.dat[i].t1_rdy,
                t2_rdy      : d_in.dat[i].t2_rdy,
                rob_idx     : d_in.dat[i].rob_idx,

                opa_select  : d_in.dat[i].opa_select,
                opb_select  : d_in.dat[i].opb_select,
                alu_func    : d_in.dat[i].alu_func
            };
        end
    end

    RS_MUL_PAYLOAD [`N-1:0] tmp_dat_mult;
    always_comb begin
        foreach (d_in.dat[i]) begin
            tmp_dat_mult[i] = '{
`ifdef DEBUG
                id          : d_in.dat[i].id,
                PC          : d_in.dat[i].PC,
                inst        : d_in.dat[i].inst,
`endif
                bmask       : d_in.dat[i].bmask,

                t           : d_in.dat[i].t,
                t1          : d_in.dat[i].t1,
                t2          : d_in.dat[i].t2,
                t1_rdy      : d_in.dat[i].t1_rdy,
                t2_rdy      : d_in.dat[i].t2_rdy,
                rob_idx     : d_in.dat[i].rob_idx,
                func        : d_in.dat[i].inst.r.funct3
            };
        end
    end

    RS_BRU_PAYLOAD [`N-1:0] tmp_dat_bru;
    always_comb begin
        foreach (d_in.dat[i]) begin
            tmp_dat_bru[i] = '{
`ifdef DEBUG
                id          : d_in.dat[i].id,
`endif
                b1hot       : d_in.dat[i].b1hot,
                bmask       : d_in.dat[i].bmask,

                PC          : d_in.dat[i].PC,
                inst        : d_in.dat[i].inst,

                t           : d_in.dat[i].t,
                t1          : d_in.dat[i].t1,
                t2          : d_in.dat[i].t2,
                t1_rdy      : d_in.dat[i].t1_rdy,
                t2_rdy      : d_in.dat[i].t2_rdy,
                rob_idx     : d_in.dat[i].rob_idx,

                opa_select  : d_in.dat[i].opa_select,
                opb_select  : d_in.dat[i].opb_select,

                btq_idx     : d_in.dat[i].btq_idx,
                cond_branch : d_in.dat[i].cond_branch
            };
        end
    end

    rs_part #(
        .FU         (FU_ALU),
        .PAYLOAD    (RS_ALU_PAYLOAD),
        .ENTRY      (RS_ALU_ENTRY),
        .PART_SZ    (RS_ALU_SZ),
        .NUM_FU     (`NUM_FU_ALU),
        .ISS_CDB_ARB(`TRUE)
    ) rs_alu (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .d_in_en        (d_in.en[FU_ALU]),
        .d_in_dat       (tmp_dat_alu),
        .d_out_rdy_sbus (d_out.rdy_sbus[FU_ALU]),

        .ex_in_fu_rdy       (ex_in.fu_rdy_alu),
        .ex_in_fu_cdb_gnt   (ex_in.fu_cdb_gnt_alu),

        .ex_out_fu_vld  (ex_out.fu_vld_alu),
        .ex_out_fu_en   (ex_out.fu_en_alu),
        .ex_out_fu_dat  (ex_out.fu_dat_alu),
        .ex_out_bytag   (ex_out.bytag_alu),

        .ctag_in(ctag_in)
    );

    rs_part #(
        .FU         (FU_MUL),
        .PAYLOAD    (RS_MUL_PAYLOAD),
        .ENTRY      (RS_MULT_ENTRY),
        .PART_SZ    (RS_MUL_SZ),
        .NUM_FU     (`NUM_FU_MUL),
        .ISS_CDB_ARB(`FALSE)
    ) rs_mul (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .d_in_en        (d_in.en[FU_MUL]),
        .d_in_dat       (tmp_dat_mult),
        .d_out_rdy_sbus (d_out.rdy_sbus[FU_MUL]),

        .ex_in_fu_rdy       (ex_in.fu_rdy_mul),
        .ex_in_fu_cdb_gnt   (),

        .ex_out_fu_vld  (),
        .ex_out_fu_en   (ex_out.fu_en_mul),
        .ex_out_fu_dat  (ex_out.fu_dat_mul),
        .ex_out_bytag   (),

        .ctag_in(ctag_in)
    );

    rs_part #(
        .FU         (FU_BRU),
        .PAYLOAD    (RS_BRU_PAYLOAD),
        .ENTRY      (RS_BRU_ENTRY),
        .PART_SZ    (RS_BRU_SZ),
        .NUM_FU     (`NUM_FU_BRU),
        .ISS_CDB_ARB(`TRUE)
    ) rs_bru (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .d_in_en        (d_in.en[FU_BRU]),
        .d_in_dat       (tmp_dat_bru),
        .d_out_rdy_sbus (d_out.rdy_sbus[FU_BRU]),

        .ex_in_fu_rdy       (ex_in.fu_rdy_bru),
        .ex_in_fu_cdb_gnt   (ex_in.fu_cdb_gnt_bru),

        .ex_out_fu_vld  (ex_out.fu_vld_bru),
        .ex_out_fu_en   (ex_out.fu_en_bru),
        .ex_out_fu_dat  (ex_out.fu_dat_bru),
        .ex_out_bytag   (ex_out.bytag_bru),

        .ctag_in(ctag_in)
    );

    // default rdy_sbus for partitions not yet defined
    assign d_out.rdy_sbus[FU_LOD]  = '0;
    assign d_out.rdy_sbus[FU_STR] = '0;

    assign ex_out.fu_en_lod    = '0;
    assign ex_out.fu_en_str     = '0;
    assign ex_out.fu_dat_lod   = '0;
    assign ex_out.fu_dat_str    = '0;

`ifdef DEBUG
    task automatic print_rs_alu(input RS_ALU_ENTRY [RS_ALU_SZ-1:0] entries);
        for (int i = 0; i < RS_ALU_SZ; ++i) begin
            if (!entries[i].busy) begin
                $display("rs_alu[%2d]:", i);
                continue;
            end
            $display("rs_alu[%2d]: {iss:%b} pc=0x%x, id=%3d (%x), t=%2d, t1=%2d%c, t2=%2d%c, rob_idx=%2d",
                i, 

                entries[i].issd, 
                entries[i].dat.PC,
                entries[i].dat.id, 
                entries[i].dat.inst,

                entries[i].dat.t, 
                entries[i].dat.t1, 
                entries[i].dat.t1_rdy ? "+" : " ", 
                entries[i].dat.t2, 
                entries[i].dat.t2_rdy ? "+" : " ", 
                entries[i].dat.rob_idx
            );
        end
    endtask

    task automatic print_rs_mul(input RS_MULT_ENTRY [RS_MUL_SZ-1:0] entries);
        for (int i = 0; i < RS_MUL_SZ; ++i) begin
            if (!entries[i].busy) begin
                $display("rs_mul[%2d]:", i);
                continue;
            end
            $display("rs_mul[%2d]: {iss:%b} pc=0x%x, id=%3d (%x), t=%2d, t1=%2d%c, t2=%2d%c, rob_idx=%2d",
                i, 

                entries[i].issd, 
                entries[i].dat.PC,
                entries[i].dat.id, 
                entries[i].dat.inst,

                entries[i].dat.t, 
                entries[i].dat.t1, 
                entries[i].dat.t1_rdy ? "+" : " ", 
                entries[i].dat.t2, 
                entries[i].dat.t2_rdy ? "+" : " ", 
                entries[i].dat.rob_idx
            );
        end
    endtask

    task automatic print_rs_bru(input RS_BRU_ENTRY [RS_BRU_SZ-1:0] entries);
        for (int i = 0; i < RS_BRU_SZ; ++i) begin
            if (!entries[i].busy) begin
                $display("rs_bru[%2d]:", i);
                continue;
            end
            $display("rs_bru[%2d]: {iss:%b} pc=0x%x, id=%3d (%x), t=%2d, t1=%2d%c, t2=%2d%c, rob_idx=%2d",
                i, 

                entries[i].issd, 
                entries[i].dat.PC,
                entries[i].dat.id, 
                entries[i].dat.inst,

                entries[i].dat.t, 
                entries[i].dat.t1, 
                entries[i].dat.t1_rdy ? "+" : " ", 
                entries[i].dat.t2, 
                entries[i].dat.t2_rdy ? "+" : " ", 
                entries[i].dat.rob_idx
            );
        end
    endtask

    task automatic print_rs;
        $display("  | >> RS >>");
        for (int n = 0; n < `N; ++n)
            print_id_result(d_in.dat[n]);
        $display("      >> RS_ALU");
        print_rs_alu(rs_alu.entries);
        $display("      >> RS_MUL");
        print_rs_mul(rs_mul.entries);
        $display("      >> RS_BRU");
        print_rs_bru(rs_bru.entries);

        $display("  | << RS <<");

    endtask
`endif
endmodule
