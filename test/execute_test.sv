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
    logic       [NUM_FU_ALU-1:0]    fu_vld_alu;
    logic       [NUM_FU_MULT-1:0]   fu_vld_mult;
    logic       [NUM_FU_STORE-1:0]  fu_vld_store;
    logic       [NUM_FU_LOAD-1:0]   fu_vld_load;
    ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load;

    logic       [NUM_FU_ALU-1:0]    fu_rdy_alu;
    logic       [NUM_FU_MULT-1:0]   fu_rdy_mult;
    logic       [NUM_FU_STORE-1:0]  fu_rdy_store;
    logic       [NUM_FU_LOAD-1:0]   fu_rdy_load;

    logic       [N-1:0]             c_en;
    PHYS_REG_IDX[N-1:0]             c_ts;
    DATA        [N-1:0]             c_data;

    // INSTANCE is from the sys_defs.svh file
    // it renames the module if SYNTH is defined in
    // order to rename the module to FIFO_svsim

    stage_ex dut (
        .clock    (clock),
        .reset    (reset),
        .fu_vld_alu(fu_vld_alu),
        .fu_vld_mult(fu_vld_mult),
        .fu_vld_store(fu_vld_store),
        .fu_vld_load(fu_vld_load),
        .fu_dat_alu(fu_dat_alu),
        .fu_dat_mult(fu_dat_mult),
        .fu_dat_store(fu_dat_store),
        .fu_dat_load(fu_dat_load),
        .fu_rdy_alu(fu_rdy_alu),
        .fu_rdy_mult(fu_rdy_mult),
        .fu_rdy_store(fu_rdy_store),
        .fu_rdy_load(fu_rdy_load),
        .c_en(c_en),
        .c_ts(c_ts),
        .c_data(c_data)
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
        $dumpfile("../ROB.vcd");
        $dumpvars(0, fetch_test.dut);
        $display("\nStart Testbench");

        clock = 0;
        reset = 1;
        fu_vld_alu = '0;
        fu_vld_mult = '0;
        fu_vld_store = '0;
        fu_vld_load = '0;
        fu_dat_alu = '0;
        fu_dat_mult = '0;
        fu_dat_store = '0;
        fu_dat_load = '0;

        $monitor("  %3d | rdy_alu: %b  rdy_mult: %b  rdy_store: %b  rdy_load: %b  |  c_en: %b  c_ts: %d  c_data: %h ",
                  $time,  fu_rdy_alu, fu_rdy_mult, fu_rdy_store, fu_rdy_load, c_en, c_ts, c_data);

        @(negedge clock);
        @(negedge clock);
        reset = 0;

        // ---------- Test 1 ---------- //
        $display("Test 1: 1 ALU instruction");
        fu_vld_alu[0] = 1;
        fu_dat_alu[0].rs1_value = 1;
        fu_dat_alu[0].rs2_value = 2;
        fu_dat_alu[0].alu_func = ALU_ADD;
        @(negedge clock);
        fu_vld_alu[0] = 0;
        @(negedge clock);

        // ---------- Test 2 ---------- //
        $display("Test 2: 2 ALU instructions");
        fu_vld_alu[0] = 1;
        fu_vld_alu[1] = 1;
        fu_dat_alu[1].rs1_value = 1;
        fu_dat_alu[1].rs2_value = 0;
        fu_dat_alu[1].alu_func = ALU_XOR;
        @(negedge clock);
        fu_vld_alu[0] = 0;
        fu_vld_alu[1] = 0;
        @(negedge clock);

        // ---------- Test 3 ---------- //
        $display("Test 3: 1 mult instruction");
        fu_vld_mult[0] = 1;
        fu_dat_mult[0].rs1_value = 3;
        fu_dat_mult[0].rs2_value = 4;
        fu_dat_mult[0].inst.r.funct3 = M_MUL;
        @(negedge clock);
        fu_vld_mult[0] = 0;
        @(negedge clock);

        // ---------- Test 4 ---------- //
        $display("Test 4: 2 mult instructions");
        fu_vld_mult[0] = 1;
        fu_vld_mult[1] = 1;
        fu_dat_mult[1].rs1_value = 2;
        fu_dat_mult[1].rs2_value = 5;
        fu_dat_mult[0].inst.r.funct3 = M_MUL;
        @(negedge clock);
        fu_vld_mult[0] = 0;
        fu_vld_mult[1] = 0;
        @(negedge clock);

        // ---------- Test 5 ---------- //
        $display("Test 5: conditional branch");
        fu_vld_alu[0] = 1;
        fu_dat_alu[0].cond_branch = 1;
        fu_dat_alu[0].rs1_value = 4
        fu_dat_alu[0].rs2_value = 5;
        fu_dat_mult[0].inst.r.funct3 = 3'b100;
        @(negedge clock);
        fu_vld_mult[1] = 0;
        @(negedge clock);

        $finish;
    end

endmodule
