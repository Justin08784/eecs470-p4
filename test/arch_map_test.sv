`include "sys_defs.svh"

`timescale 1ns / 1ps
module arch_map_testbench;
    parameter N = 2;  // Single retire per cycle
    localparam NUM_ARCH_REG = 32;
    
    logic clock, reset;
    
    // Retire signals
    rob2retire r_in;

    // Instantiate the DUT (Device Under Test)
    arch_map #(N) dut (
        .clock(clock),
        .reset(reset),
        .r_in(r_in)
    );

    // Clock generation (period = 10ns)
    always #5 clock = ~clock;

    // Test Procedure
    initial begin
        $display("Starting arch_map Testbench...");
        $dumpfile("../arch_map.vcd");
        $dumpvars(0, arch_map_testbench.dut);

        // Initialize signals
        clock = 0;
        reset = 1;
        r_in = '0;
        #10 reset = 0;

        // 🟢 **Test 1: Basic Retirement**
        r_in.r_en_cnt = 1;    // One instruction retiring
        r_in.dst[0] = 5;   // Writing to logical register 5
        r_in.tag[0]   = 20;  // Mapping new physical register PR20

        #10;  // Wait for retirement to take effect

        // Check if reg 5 now maps to PR20
        if (dut.entries[5].t == 20) $display("✅ Test 1 Passed: Register correctly retired!");
        else $error("❌ Test 1 Failed! Expected entries[5].t == 20, but got: %0d", dut.entries[5].t);

        // 🟢 **Test 2: Zero Register Handling**
        r_in.r_en_cnt = 1;
        r_in.dst[0] = `ZERO_REG; // Trying to retire `ZERO_REG`
        r_in.tag[0] = 25;          // Attempt to assign PR25

        #10;

        // Zero register should still map to PR0
        if (dut.entries[`ZERO_REG].t == 0) $display("✅ Test 2 Passed: ZERO_REG remains PR0!");
        else $error("❌ Test 2 Failed! Expected entries[`ZERO_REG].t == 0, but got: %0d", dut.entries[`ZERO_REG].t);

        // 🟢 **Test 3: Multi-Retire Handling**
        r_in.r_en_cnt = 2;    // Two retirementag in the same cycle
        r_in.dst = '{7, 9};  // Writing to logical registers 7 and 9
        r_in.tag   = '{30, 31}; // Mapping to PR30 and PR31

        #10;

        // Check that both registers are updated correctly
        if (dut.entries[7].t == 30 && dut.entries[9].t == 31) 
            $display("✅ Test 3 Passed: Multi-retire working!");
        else
            $error("❌ Test 3 Failed! Expected entries[7].t == 30, entries[9].t == 31, but got: entries[7] = %0d, entries[9] = %0d", 
                   dut.entries[7].t, dut.entries[9].t);

        // 🟢 **Test 4: Consecutive Retirementag**
        r_in.r_en_cnt = 1;
        r_in.dst[0] = 7;   // Overwriting register 7
        r_in.tag[0]   = 35;  // New mapping PR35

        #10;

        // Register 7 should now map to PR35
        if (dut.entries[7].t == 35) $display("✅ Test 4 Passed: Consecutive retirement updated!");
        else $error("❌ Test 4 Failed! Expected entries[7].t == 35, but got: %0d", dut.entries[7].t);

        // 🟢 **Test 5: Reset Behavior**
        reset = 1;
        #10 reset = 0; // Apply reset

        // All registers should be zero except ZERO_REG, which remains PR0
       // int fail_flag = 0;
       /* for (int i = 0; i < NUM_ARCH_REG; i++) begin
            if (i == `ZERO_REG) continue;
            if (dut.entries[i].t != 0) begin
                $error("❌ Test 5 Failed! Expected entries[%0d].t == 0 after reset, but got: %0d", i, dut.entries[i].t);
                fail_flag = 1;
            end
        end
        if (!fail_flag) $display("✅ Test 5 Passed: Reset correctly cleared entries!");*/

        $display("All testag completed.");
        $finish;
    end
endmodule
