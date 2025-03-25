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

    logic clock, reset;
    rs2execute rs_in;
    execute2rs rs_out;
    execute2prf prf_out;
    prf2execute prf_in;
    execute2complete c_out;

    stage_ex_p4 dut (
        .clock  (clock),
        .reset  (reset),
        .flush  (1'b0),
        .rs_in  (rs_in),
        .rs_out (rs_out),
        .prf_in (prf_in),
        .prf_out(prf_out),
        .c_out  (c_out)
    );

    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    always @(posedge clock) begin
        $monitor("  %3d | rdy_alu: %b  rdy_mult: %b  rdy_store: %b  rdy_load: %b  |  c_en: %b  c_ts: %d  c_data: %h c_rob_idxs: %d",
            $time,
            rs_out.fu_rdy_alu,
            rs_out.fu_rdy_mult,
            rs_out.fu_rdy_store,
            rs_out.fu_rdy_load,
            c_out.c_en,
            c_out.c_ts,
            c_out.c_data,
            c_out.c_rob_idxs
        );
    end

    initial begin
        $display("\nStart Testbench");

        clock   = 0;
        reset   = 1;
        rs_in   = '0;
        prf_in  = '0;


        @(negedge clock);
        reset = 0;
        @(negedge clock);
        @(negedge clock);

        // ---------- Test 1 ---------- //
        $display("Test 1: 1 ALU instruction");
        rs_in.fu_vld_alu[0] = 1;
        prf_in.s_v1s[0] = 1;
        prf_in.s_v2s[0] = 2;
        rs_in.fu_dat_alu[0].alu_func = ALU_ADD;
        rs_in.fu_dat_alu[0].t = 33;
        @(negedge clock);
        rs_in.fu_vld_alu[0] = 0;
        
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);

        // $finish;

        // // ---------- Test 2 ---------- //
        // $display("Test 2: 2 ALU instructions");
        // rs_in.fu_vld_alu[0] = 1;
        // rs_in.fu_vld_alu[1] = 1;
        // prf_in.s_v1s[0] = 7;
        // prf_in.s_v2s[0] = 5;
        // rs_in.fu_dat_alu[0].alu_func = ALU_SUB;
        // prf_in.s_v1s[1] = 1;
        // prf_in.s_v2s[1] = 0;
        // rs_in.fu_dat_alu[1].alu_func = ALU_XOR;
        // @(negedge clock);
        // rs_in.fu_vld_alu[0] = 0;
        // rs_in.fu_vld_alu[1] = 0;
        // @(negedge clock);

        // ---------- Test 3 ---------- //
        $display("Test 3: 1 mult instruction");
        rs_in.fu_vld_mult[0] = 1;
        prf_in.s_v1s[0 + `NUM_FU_ALU] = 105;
        prf_in.s_v2s[0 + `NUM_FU_ALU] = 257;
        rs_in.fu_dat_mult[0].inst.r.funct3 = M_MUL;
        @(negedge clock);
        rs_in.fu_vld_mult[0] = 0;
        @(negedge clock);

        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);

        $finish;

        // // ---------- Test 4 ---------- //
        // $display("Test 4: 2 mult instructions");
        // rs_in.fu_vld_mult[0] = 1;
        // rs_in.fu_vld_mult[1] = 1;
        // prf_in.s_v1s[0] = 24;
        // prf_in.s_v2s[0] = 2;
        // rs_in.fu_dat_mult[0].inst.r.funct3 = M_MUL; 
        // prf_in.s_v1s[1] = 2;
        // prf_in.s_v2s[1] = 5;
        // rs_in.fu_dat_mult[1].inst.r.funct3 = M_MUL; 
        // @(negedge clock);
        // rs_in.fu_vld_mult[0] = 0;
        // rs_in.fu_vld_mult[1] = 0;
        // @(negedge clock);

        // // ---------- Test 5 ---------- //
        // $display("Test 5: conditional branch");
        // rs_in.fu_vld_alu[0] = 1;
        // rs_in.fu_dat_alu[0].cond_branch = 1;
        // prf_in.s_v1s[0] = 4;
        // prf_in.s_v2s[0] = 5;
        // rs_in.fu_dat_mult[0].inst.b.funct3 = 3'b100;
        // @(negedge clock);
        // rs_in.fu_vld_mult[1] = 0;
        // @(negedge clock);
        // @(negedge clock);
        // @(negedge clock);
        // @(negedge clock);
        // @(negedge clock);
        // @(negedge clock);
        // @(negedge clock);
        // @(negedge clock);
        // @(negedge clock);

        $finish;
    end

endmodule
