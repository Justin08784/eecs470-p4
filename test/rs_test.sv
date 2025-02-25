
`include "sys_defs.svh"
`include "test/rs_sva.svh"
/*
CLARIFICATION NEEDED:
Ok, checking the accuracy of FF state like entries_dbg seems pretty
straightforward. But how to check correctness of combinational stuff like
s_vld, rs_scnt? Aren't there timing issues?
*/


typedef struct packed {
    logic       [$clog2(N):0]       rs_scnt; // to dispatcher
    logic       [NUM_FU_ALU-1:0]    fu_vld_alu;
    logic       [NUM_FU_MULT-1:0]   fu_vld_mult;
    logic       [NUM_FU_STORE-1:0]  fu_vld_store;
    logic       [NUM_FU_LOAD-1:0]   fu_vld_load;
    ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load;
} RS_OUTS;

RS_OUTS model_out;
function int model_update(
    // input   clock,
    input   reset,
    input   flush,

    // dispatch
    input   logic       [$clog2(N):0]       rs_scnt, // to dispatcher
    input   logic       [N-1:0]             d_vld,     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    input   ID_RESULT   [N-1:0]             d_dat,

    // issue
    input   logic       [NUM_FU_ALU-1:0]    fu_rdy_alu,
    input   logic       [NUM_FU_MULT-1:0]   fu_rdy_mult,
    input   logic       [NUM_FU_STORE-1:0]  fu_rdy_store,
    input   logic       [NUM_FU_LOAD-1:0]   fu_rdy_load,

    input   logic       [NUM_FU_ALU-1:0]    fu_vld_alu,
    input   logic       [NUM_FU_MULT-1:0]   fu_vld_mult,
    input   logic       [NUM_FU_STORE-1:0]  fu_vld_store,
    input   logic       [NUM_FU_LOAD-1:0]   fu_vld_load,
    input   ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu,
    input   ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult,
    input   ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store,
    input   ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load,

    input   logic           [N-1:0] c_en,
    input   PHYS_REG_IDX    [N-1:0] c_ts

);
    static RS_ENTRY [RS_SZ-1:0] entries;

    if (reset || flush) begin
        entries = '0;
    end

endfunction


module rs_testbench;
    // constants

    // signals
    logic clock;
    logic reset;
    logic flush;

    logic           [$clog2(N):0] rs_scnt; // to dispatcher
    logic           [N-1:0] d_vld;     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    ID_RESULT       [N-1:0] d_dat;
    // issue
    logic           [NUM_FU_ALU-1:0]    fu_rdy_alu;
    logic           [NUM_FU_MULT-1:0]   fu_rdy_mult;
    logic           [NUM_FU_STORE-1:0]  fu_rdy_store;
    logic           [NUM_FU_LOAD-1:0]   fu_rdy_load;

    logic           [NUM_FU_ALU-1:0]    fu_vld_alu;
    logic           [NUM_FU_MULT-1:0]   fu_vld_mult;
    logic           [NUM_FU_STORE-1:0]  fu_vld_store;
    logic           [NUM_FU_LOAD-1:0]   fu_vld_load;
    ID_RESULT       [NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT       [NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT       [NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT       [NUM_FU_LOAD-1:0]   fu_dat_load;
    // complete (CDB)
    logic           [N-1:0] c_en;
    PHYS_REG_IDX    [N-1:0] c_ts;

    logic failed;
    // DATA r1, r2, correct_r, mul_r;
    string fmt;

    rs # (
        .N(N),
        .RS_SZ(RS_SZ),
        .FU_IDX_NUM(FU_IDX_NUM),
        .NUM_FU_ALU(NUM_FU_ALU),
        .NUM_FU_MULT(NUM_FU_MULT),
        .NUM_FU_STORE(NUM_FU_STORE),
        .NUM_FU_LOAD(NUM_FU_LOAD)
    ) rs_dut(
        .clock(clock),
        .reset(reset),
        .flush(1'b0),

        .rs_scnt(rs_scnt),
        .d_vld(d_vld),
        .d_dat(d_dat),

        .fu_rdy_alu(fu_rdy_alu),
        .fu_rdy_mult(fu_rdy_mult),
        .fu_rdy_store(fu_rdy_store),
        .fu_rdy_load(fu_rdy_load),

        .fu_vld_alu(fu_vld_alu),
        .fu_vld_mult(fu_vld_mult),
        .fu_vld_store(fu_vld_store),
        .fu_vld_load(fu_vld_load),
        .fu_dat_alu(fu_dat_alu),
        .fu_dat_mult(fu_dat_mult),
        .fu_dat_store(fu_dat_store),
        .fu_dat_load(fu_dat_load),

        .c_en(c_en),
        .c_ts(c_ts)
    );

    bind rs_dut rs_sva # (
        .N(N),
        .RS_SZ(RS_SZ),
        .FU_IDX_NUM(FU_IDX_NUM),
        .NUM_FU_ALU(NUM_FU_ALU),
        .NUM_FU_MULT(NUM_FU_MULT),
        .NUM_FU_STORE(NUM_FU_STORE),
        .NUM_FU_LOAD(NUM_FU_LOAD)
    ) dut_sva (
        .clock(clock),
        .reset(reset),
        .flush(1'b0),

        .rs_scnt(rs_scnt),
        .d_vld(d_vld),
        .d_dat(d_dat),

        .fu_rdy_alu(fu_rdy_alu),
        .fu_rdy_mult(fu_rdy_mult),
        .fu_rdy_store(fu_rdy_store),
        .fu_rdy_load(fu_rdy_load),

        .c_en(c_en),
        .c_ts(c_ts),


        .entries_dut(rs_dut.entries),
        .fu_vld_alu_dut(rs_dut.fu_vld_alu),
        .fu_vld_mult_dut(rs_dut.fu_vld_mult),
        .fu_vld_store_dut(rs_dut.fu_vld_store),
        .fu_vld_load_dut(rs_dut.fu_vld_load)
    );

    task set_dispatch(
        input int i,
        input int t1,
        input int t2,
        input int t1_rdy,
        input int t2_rdy,
        input int fu_idx
    );
        // Set up a valid dispatch line
        d_vld[i]        = 1;

        d_dat[i]        = '0;
        d_dat[i].t1     = t1;
        d_dat[i].t2     = t2;
        d_dat[i].t1_rdy = t1_rdy;
        d_dat[i].t2_rdy = t2_rdy;
        d_dat[i].fu_idx = fu_idx;
    endtask

    task clr_dispatch(
        input int i
    );
        d_vld[i] = 0;
        d_dat[i] = '0;
    endtask

    task set_cdb(
        input int i,
        input int t
    );
        c_en[i] = 1;
        c_ts[i]  = t;
    endtask

    task clr_cdb(
        input int i
    );
        c_en[i] = 0;
        c_ts[i]  = '0;
    endtask

    task set_fu(
        input FU_IDX fu,
        input int i
    );
        case (fu)
            FU_ALU:     fu_rdy_alu[i]   = 1;
            FU_MULT:    fu_rdy_mult[i]  = 1;
            FU_LOAD:    fu_rdy_load[i]  = 1;
            FU_STORE:   fu_rdy_store[i] = 1;
        endcase
    endtask

    task clr_fu(
        input FU_IDX fu,
        input int i
    );
        case (fu)
            FU_ALU:     fu_rdy_alu[i]   = 0;
            FU_MULT:    fu_rdy_mult[i]  = 0;
            FU_LOAD:    fu_rdy_load[i]  = 0;
            FU_STORE:   fu_rdy_store[i] = 0;
        endcase
    endtask



    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end


    task test_1inst();
        reset   = 1;
        @(negedge clock);
        @(negedge clock);

        reset = 0;
        @(negedge clock);

        set_dispatch(1, 2, 4, 0, 0, 1);
        @(posedge clock);
        // $display("s_vld: %b", s_vld);
        @(negedge clock);

        clr_dispatch(0);
        clr_dispatch(1);
        set_cdb(0, 1);
        set_cdb(1, 2);
        @(posedge clock);
        @(negedge clock);

        // ask about timing; why does s_vld display need to be after posedge?
        clr_cdb(0);
        clr_cdb(1);
        set_fu(FU_ALU, 0);
        @(posedge clock);
        @(negedge clock);

        @(posedge clock);
        @(negedge clock);


    endtask
    initial begin
        /* initialize */
        clock           = 0;
        failed          = 0;
        d_vld           = '0;
        d_dat           = '0;
        fu_rdy_alu      = '0;
        fu_rdy_mult     = '0;
        fu_rdy_store    = '0;
        fu_rdy_load     = '0;
        c_en            = '0;
        c_ts            = '0;

        reset = 1;
        @(negedge clock);
        @(negedge clock);
        reset = 0;
        @(negedge clock);

        set_dispatch(1, 2, 4, 0, 0, 1);
        // set_dispatch(0, 3, 6, 0, 0, 1);
        @(posedge clock);

        for (int i = 0; i < 10; ++i) begin
            @(negedge clock);
        end


        clr_dispatch(1);
        set_cdb(0, 2);
        @(negedge clock);

        clr_cdb(0);
        set_cdb(1, 4);
        @(negedge clock);

        clr_cdb(1);
        set_fu(FU_MULT, 0);
        set_fu(FU_MULT, 1);
        @(negedge clock);

        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);

        if (failed)
            $display("@@@ Failed\n");
        else
            $display("@@@ Passed\n");

        $finish;
    end

endmodule
