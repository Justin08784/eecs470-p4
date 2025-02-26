
`include "sys_defs.svh"
`include "test/rs_sva.svh"

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

    task clr_all();
        d_vld = '0;
        d_dat = '0;
        c_en = '0;
        c_ts = '0;
        fu_rdy_alu = '0;
        fu_rdy_mult = '0;
        fu_rdy_load = '0;
        fu_rdy_store = '0;
    endtask



    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end


    task test_1inst();
        reset = 1;
        @(negedge clock);
        reset = 0;

        // ID[1]: p? <- p2{!rdy} * p4{!rdy}
        set_dispatch(1, 2, 4, 0, 0, FU_MULT);
        @(negedge clock);
        clr_dispatch(1);

        // CDB: [p2, -]
        set_cdb(0, 2);
        @(negedge clock);
        clr_cdb(0);

        // CDB: [-, p4]
        set_cdb(1, 4);
        @(negedge clock);
        clr_cdb(1);

        // fu_rdy_mult[0] <- 1
        set_fu(FU_MULT, 0);
        @(negedge clock);

        @(negedge clock);

        @(negedge clock);

        clr_all();

    endtask


    task test_back_to_back();
        reset = 1;
        @(negedge clock);
        reset = 0;
        set_dispatch(0, 3, 4, 0, 1, FU_ALU);
        @(negedge clock);
        set_dispatch(1, 5, 6, 1, 0, FU_MULT);
        @(negedge clock);
        clr_dispatch(0);
        clr_dispatch(1);
        set_cdb(0, 3);
        set_cdb(1, 5);
        @(negedge clock);
        clr_cdb(0);
        clr_cdb(1);
        set_fu(FU_ALU, 0);
        set_fu(FU_MULT, 0);
        @(negedge clock);
        clr_all();
    endtask

    task test_multiple_cdb();
        reset = 1;
        @(negedge clock);
        reset = 0;
        set_dispatch(0, 7, 8, 0, 0, FU_STORE);
        set_dispatch(1, 9, 10, 1, 1, FU_LOAD);
        @(negedge clock);
        clr_dispatch(0);
        clr_dispatch(1);
        set_cdb(0, 7);
        set_cdb(1, 9);
        set_cdb(2, 8);
        set_cdb(3, 10);
        @(negedge clock);
        clr_cdb(0);
        clr_cdb(1);
        clr_cdb(2);
        clr_cdb(3);
        set_fu(FU_STORE, 0);
        set_fu(FU_LOAD, 0);
        @(negedge clock);
        clr_all();
    endtask


    task test_sequential_fu();
        reset = 1;
        @(negedge clock);
        reset = 0;
        set_dispatch(0, 11, 12, 0, 1, FU_ALU);
        @(negedge clock);
        clr_dispatch(0);
        set_cdb(0, 11);
        @(negedge clock);
        clr_cdb(0);
        set_dispatch(1, 13, 14, 1, 0, FU_MULT);
        @(negedge clock);
        clr_dispatch(1);
        set_cdb(1, 13);
        @(negedge clock);
        clr_cdb(1);
        set_fu(FU_ALU, 0);
        @(negedge clock);
        clr_all();
    endtask

    task test_mixed();
        reset = 1;
        @(negedge clock);
        reset = 0;
        set_dispatch(0, 2, 3, 0, 1, FU_ALU);
        set_dispatch(1, 4, 5, 1, 0, FU_MULT);
        set_dispatch(2, 6, 7, 0, 0, FU_LOAD);
        @(negedge clock);
        clr_dispatch(0);
        clr_dispatch(1);
        clr_dispatch(2);
        set_cdb(0, 2);
        @(negedge clock);
        clr_cdb(0);
        set_cdb(1, 4);
        @(negedge clock);
        clr_cdb(1);
        set_cdb(2, 6);
        @(negedge clock);
        clr_cdb(2);
        set_fu(FU_ALU, 0);
        set_fu(FU_MULT, 0);
        set_fu(FU_LOAD, 0);
        @(negedge clock);
        clr_all();
    endtask

    task test_idle();
        reset = 1;
        @(negedge clock);
        reset = 0;
        @(negedge clock);
        @(negedge clock);
        clr_all();
    endtask


    task test_multi_1();
        reset = 1;
        @(negedge clock);
        reset = 0;
        
        $display("### Starting Multiple Instruction Test ###");

        // ID[0]: p? <- p1 * p2
        set_dispatch(0, 1, 2, 0, 0, FU_MULT);
        // ID[1]: p? <- (p3+) + p4
        set_dispatch(1, 3, 4, 1, 0, FU_ALU);
        @(negedge clock);
        clr_dispatch(0);
        clr_dispatch(1);

        // ID[0]: p? <- M[p8+]
        set_dispatch(0, 8, 0, 1, 1, FU_LOAD);
        set_cdb(0, 1);
        @(negedge clock);
        clr_cdb(0);

        set_cdb(1, 2);
        @(negedge clock);
        clr_cdb(1);

        set_fu(FU_ALU, 0);  // ALU unit ready
        @(negedge clock);

        set_cdb(2, 4);
        @(negedge clock);
        clr_cdb(2);

        set_fu(FU_MULT, 0);
        @(negedge clock);

        set_fu(FU_LOAD, 0);
        @(negedge clock);

        set_cdb(0, 5);  // MULT result p5
        @(negedge clock);
        clr_cdb(0);

        set_cdb(1, 6);  // ALU result p6
        @(negedge clock);
        clr_cdb(1);

        set_cdb(2, 7);  // Load result p7
        @(negedge clock);
        clr_cdb(2);

        @(negedge clock);
        @(negedge clock);
        clr_all();

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

        test_1inst();
        test_multi_1();
        test_idle();
        test_mixed();
        test_sequential_fu();
        test_multiple_cdb();
        test_back_to_back();

    
        if (failed)
            $display("@@@ Failed\n");
        else
            $display("@@@ Passed\n");

        $finish;
    end

endmodule
