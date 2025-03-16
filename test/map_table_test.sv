`include "sys_defs.svh"

`timescale 1ns / 1ps
module map_table_testbench;
    parameter N = 2;  // Single-issue architecture
    localparam NUM_ARCH_REG = 32;
    
    logic clock, reset;
    
    // // Completion signals
    // typedef struct packed {
    //     logic         [N-1:0] c_en;
    //     PHYS_REG_IDX  [N-1:0] c_ts;
    // } CompletionSignals;

    // Dispatch signals
    // typedef struct packed {
    //     logic         [$clog2(N):0] en_cnt;
    //     REG_IDX       [N-1:0] src1s;
    //     REG_IDX       [N-1:0] src2s;
    //     REG_IDX       [N-1:0] dsts;
    //     PHYS_REG_IDX  [N-1:0] ts;
    // } DispatchSignals;

    // Map table outputs
    // typedef struct packed {
    //     logic        [N-1:0] cpl1s;
    //     logic        [N-1:0] cpl2s;
    //     PHYS_REG_IDX [N-1:0] t1s;
    //     PHYS_REG_IDX [N-1:0] t2s;
    // }  DispatchOutput;

    execute2complete c_in;
    dispatch2map_table d_in;
    map_table2rob rob_out;
    map_table2dispatch dispatch_out;


    // Instantiate the DUT (Device Under Test)
    map_table #(N) dut (
        .clock(clock),
        .reset(reset),
        .c_in(c_in),
        .d_in(d_in),
        .dispatch_out(dispatch_out)
    );

    // Clock generation (period = 10ns)
    always #5 clock = ~clock;

    // Test Procedure
    initial begin
        $display("Starting map_table Single-Scalar Testbench...");
         $dumpfile("../map_table.vcd");
         $dumpvars(0, map_table_testbench.dut);

        // Initialize signals
        clock = 0;
        reset = 1;
        d_in = '0;
        c_in = '0;
        #10 reset = 0;

        // 🟢 **Test 1: Basic Register Mapping (Single Instruction)**
        d_in.en_cnt = 1;     // Single instruction dispatch
        d_in.src1s[0] = 1;   // Read from logical register 1
        d_in.src2s[0] = 2;   // Read from logical register 2
        d_in.dsts[0] = 3;    // Writing to logical register 3
        d_in.ts[0]   = 10;   // Mapping new physical register P10

        #10;  // Wait for renaming to complete

        // Print debug info
        $display("DEBUG: Test 1 - Expected dispatch_out.t1s[0] != 0");
        $display("       src1: %0d -> mapped to t1: %0d", d_in.src1s[0], dispatch_out.t1s[0]);
        $display("       src2: %0d -> mapped to t2: %0d", d_in.src2s[0], dispatch_out.t2s[0]);
        $display("       dst: %0d -> mapped to new ts: %0d", d_in.dsts[0], d_in.ts[0]);

        if (dispatch_out.t1s[0] == 1 && dispatch_out.t2s[0] == 2) $display("✅ Test 1 Passed: Register renamed!");
        else begin
            $error("❌ Test 1 Failed! Expected dispatch_out.t1s[0] != 0, but got: %0d", dispatch_out.t1s[0]);
        end

        // 🟢 **Test 2: Register Completion (Single Instruction)**
        c_in.c_en[0] = 1;   // One instruction completes
        c_in.c_ts[0] = 10;  // Completed physical register P10

        #10;  // Wait for update

        // Print debug info
        $display("DEBUG: Test 2 - Expected dispatch_out.cpl1s[0] == 1");
        $display("       Completed physical reg: %0d", c_in.c_ts[0]);
        $display("       Completion status (cpl1s[0]): %0d", dispatch_out.cpl1s[0]);

        if (dispatch_out.cpl1s[0] == 1) $display("✅ Test 2 Passed: Register completion correct!");
        else begin
            $error("❌ Test 2 Failed! Expected dispatch_out.cpl1s[0] == 1, but got: %0d", dispatch_out.cpl1s[0]);
        end

        // 🟢 **Test 3: Zero Register Handling**
        d_in.en_cnt = 1;
        d_in.dsts[0] = `ZERO_REG;  // Trying to rename ZERO_REG
        d_in.ts[0] = 20;           // Attempt to assign P20

        #10;

        // Print debug info
        $display("DEBUG: Test 3 - Expected dispatch_out.t1s[0] == 0");
        $display("       Zero register mapping: %0d", dispatch_out.t1s[0]);

        if (dispatch_out.t1s[0] == 0) $display("✅ Test 3 Passed: ZERO_REG handling correct!");
        else begin
            $error("❌ Test 3 Failed! Expected dispatch_out.t1s[0] == 0, but got: %0d", dispatch_out.t1s[0]);
        end

        // 🟢 **Test 4: Multi-Dispatch Renaming**
        d_in.en_cnt = 2;  // Two instructions dispatched
        d_in.src1s = '{5, 7};  // Read from logical reg 5 and newly renamed 7
        d_in.src2s = '{6, 8};
        d_in.dsts  = '{7, 9};  // Writing to logical registers 7 and 9
        d_in.ts    = '{20, 21}; // Mapping new physical registers PR20, PR21

        #10;  // Wait for renaming

        // Print debug info
        $display("DEBUG: Test 4 - Checking multi-dispatch register renaming");
        $display("       src1[0]: %0d -> mapped to t1: %0d", d_in.src1s[0], dispatch_out.t1s[0]);
        $display("       src2[0]: %0d -> mapped to t2: %0d", d_in.src2s[0], dispatch_out.t2s[0]);
        $display("       dst[0]: %0d -> new mapping: %0d", d_in.dsts[0], d_in.ts[0]);

        $display("       src1[1]: %0d -> mapped to t1: %0d (should be 20)", d_in.src1s[1], dispatch_out.t1s[1]);
        $display("       src2[1]: %0d -> mapped to t2: %0d", d_in.src2s[1], dispatch_out.t2s[1]);
        $display("       dst[1]: %0d -> new mapping: %0d", d_in.dsts[1], d_in.ts[1]);

        if (dispatch_out.t1s[0] == 20) $display("✅ Test 4 Passed: Multi-dispatch renaming correct!");
        else $error("❌ Test 4 Failed! Expected dispatch_out.t1s[1] == 20, but got: %0d", dispatch_out.t1s[0]);


        // 🟢 **Test 5: Overwriting a Register Mapping**
        d_in.en_cnt = 1;
        d_in.src1s[0] = 10;
        d_in.dsts[0] = 10;
        d_in.ts[0] = 30;  // First mapping to PR30
        #10;

        d_in.ts[0] = 31;  // Overwrite with PR31
        #10;

        $display("DEBUG: Test 5 - Checking register overwrite behavior");
        $display("       src1: %0d -> mapped to t1: %0d (should be 31)", d_in.src1s[0], dispatch_out.t1s[0]);

        if (dispatch_out.t1s[0] == 31) $display("✅ Test 5 Passed: Register overwrite handled correctly!");
        else $error("❌ Test 5 Failed! Expected dispatch_out.t1s[0] == 31, but got: %0d", dispatch_out.t1s[0]);


        // 🟢 **Test 6: Completing multiple registers in one cycle**
        c_in.c_en = 2'b11;  // Two registers completing
        c_in.c_ts = '{12, 13};
        d_in.en_cnt = 2'b00;

        #10;  // Wait for update

        // Print debug info
        $display("DEBUG: Test 6 - Checking multiple register completion");
        $display("       Completed physical reg: %0d -> cpl1s: %0d", c_in.c_ts[0], dispatch_out.cpl1s[0]);
        $display("       Completed physical reg: %0d -> cpl1s: %0d", c_in.c_ts[1], dispatch_out.cpl1s[1]);

        if (dispatch_out.cpl1s[0] && dispatch_out.cpl1s[1]) $display("✅ Test 6 Passed: Multi-completion correct!");
        else $error("❌ Test 6 Failed! Completion status incorrect!");





        $display("All tests completed.");
        $finish;

    end
endmodule
