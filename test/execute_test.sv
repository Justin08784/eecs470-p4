// Fetch module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh
`include "sys_defs.svh"



module execute_test();
    localparam N=`N;
    localparam NUM_FU_ALU=`NUM_FU_ALU;
    localparam NUM_FU_MULT=`NUM_FU_MULT;
    localparam NUM_FU_LOAD=`NUM_FU_LOAD;
    localparam NUM_FU_STORE=`NUM_FU_STORE;

    logic                           clock, reset;

    rs2execute ex_fu_in;
    
    /*logic       [NUM_FU_ALU-1:0]    fu_vld_alu;
    logic       [NUM_FU_MULT-1:0]   fu_vld_mult;
    logic       [NUM_FU_STORE-1:0]  fu_vld_store;
    logic       [NUM_FU_LOAD-1:0]   fu_vld_load;
    ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load;*/

    prf2execute prf_2_ex;


    execute2rs ex_rdy_out;


    /*logic       [NUM_FU_ALU-1:0]    fu_rdy_alu;
    logic       [NUM_FU_MULT-1:0]   fu_rdy_mult;
    logic       [NUM_FU_STORE-1:0]  fu_rdy_store;
    logic       [NUM_FU_LOAD-1:0]   fu_rdy_load;*/

    execute2complete ex_c_out;

    /*logic       [N-1:0]             c_en;
    PHYS_REG_IDX[N-1:0]             c_ts;
    DATA        [N-1:0]             c_data;*/

    // INSTANCE is from the sys_defs.svh file
    // it renames the module if SYNTH is defined in
    // order to rename the module to FIFO_svsim

    stage_ex_p4 dut (
        .clock    (clock),
        .reset    (reset),
        .ex_fu_in (ex_fu_in),
        .prf_2_ex (prf_2_ex),
        .ex_rdy_out(ex_rdy_out),
        .ex_c_out(ex_c_out)

    );

    // bind dut rob_sva #(
    //     .DEPTH(`DEPTH),
    //     .WIDTH(`WIDTH)
    // ) DUT_sva (
    //     .clock    (clock),
    //     .reset    (reset)
    //     // .wr_en (wr_en),
    //     // .rd_en (rd_en),
    //     // .err      (err),
    //     // .wr_data (wr_data),
    //     // .wr_valid (wr_valid),
    //     // .rd_valid (rd_valid),
    //     // .rd_data  (rd_data),
    //     // .spots    (spots),
    //     // .full     (full)
    // );

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    // Generate random numbers for our write data on each cycle
    // always @(negedge clock) begin
    //     std::randomize();
    // end

    initial begin

        //Instantiate mem module to give it initial values, then try modifying unified memory in here
        $dumpfile("../execute.vcd");
        $dumpvars(0, execute_test.dut);
        $display("\nStart Testbench");

        clock = 0;
        reset = 1;
        ex_fu_in.fu_vld_alu = '0;
        ex_fu_in.fu_vld_mult = '0;
        ex_fu_in.fu_vld_store = '0;
        ex_fu_in.fu_vld_load = '0;
        ex_fu_in.fu_dat_alu = '0;
        ex_fu_in.fu_dat_mult = '0;
        ex_fu_in.fu_dat_store = '0;
        ex_fu_in.fu_dat_load = '0;

        $monitor("  %3d | rdy_alu: %b  rdy_mult: %b  rdy_store: %b  rdy_load: %b  |  c_en: %b  c_ts: %d  c_data: %h c_rob_idxs: %d",
                  $time,  ex_rdy_out.fu_rdy_alu, ex_rdy_out.fu_rdy_mult, ex_rdy_out.fu_rdy_store, ex_rdy_out.fu_rdy_load, ex_c_out.c_en, ex_c_out.c_ts, ex_c_out.c_data, ex_c_out.c_rob_idxs);

        @(negedge clock);
        @(negedge clock);
        reset = 0;

        // ---------- Test 1 ---------- //
        $display("Test 1: 1 ALU instruction");
        ex_fu_in.fu_vld_alu[0] = 1;
        prf_2_ex.s_v1s[0] = 1;
        prf_2_ex.s_v2s[0] = 2;
        ex_fu_in.fu_dat_alu[0].alu_func = ALU_ADD;
        @(negedge clock);
        ex_fu_in.fu_vld_alu[0] = 0;
        @(negedge clock);

        // ---------- Test 2 ---------- //
        $display("Test 2: 2 ALU instructions");
        ex_fu_in.fu_vld_alu[0] = 1;
        ex_fu_in.fu_vld_alu[1] = 1;
        prf_2_ex.s_v1s[0] = 7;
        prf_2_ex.s_v2s[0] = 5;
        ex_fu_in.fu_dat_alu[0].alu_func = ALU_SUB;
        prf_2_ex.s_v1s[1] = 1;
        prf_2_ex.s_v2s[1] = 0;
        ex_fu_in.fu_dat_alu[1].alu_func = ALU_XOR;
        @(negedge clock);
        ex_fu_in.fu_vld_alu[0] = 0;
        ex_fu_in.fu_vld_alu[1] = 0;
        @(negedge clock);

        // ---------- Test 3 ---------- //
        $display("Test 3: 1 mult instruction");
        ex_fu_in.fu_vld_mult[0] = 1;
        prf_2_ex.s_v1s[0] = 3;
        prf_2_ex.s_v2s[0] = 4;
        ex_fu_in.fu_dat_mult[0].inst.r.funct3 = M_MUL;
        @(negedge clock);
        ex_fu_in.fu_vld_mult[0] = 0;
        @(negedge clock);

        // ---------- Test 4 ---------- //
        $display("Test 4: 2 mult instructions");
        ex_fu_in.fu_vld_mult[0] = 1;
        ex_fu_in.fu_vld_mult[1] = 1;
        prf_2_ex.s_v1s[0] = 24;
        prf_2_ex.s_v2s[0] = 2;
        ex_fu_in.fu_dat_mult[0].inst.r.funct3 = M_MUL; 
        prf_2_ex.s_v1s[1] = 2;
        prf_2_ex.s_v2s[1] = 5;
        ex_fu_in.fu_dat_mult[1].inst.r.funct3 = M_MUL; 
        @(negedge clock);
        ex_fu_in.fu_vld_mult[0] = 0;
        ex_fu_in.fu_vld_mult[1] = 0;
        @(negedge clock);

        // ---------- Test 5 ---------- //
        $display("Test 5: conditional branch");
        ex_fu_in.fu_vld_alu[0] = 1;
        ex_fu_in.fu_dat_alu[0].cond_branch = 1;
        prf_2_ex.s_v1s[0] = 4;
        prf_2_ex.s_v2s[0] = 5;
        ex_fu_in.fu_dat_mult[0].inst.b.funct3 = 3'b100;
        @(negedge clock);
        ex_fu_in.fu_vld_mult[1] = 0;
        @(negedge clock);

        $finish;
    end

endmodule
