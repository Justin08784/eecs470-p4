// FIFO module testbench
// This module generates the test vectors
// Correctness checking is in FIFO_sva.svh

`include "sys_defs.svh"
`include "FIFO_sva.svh"

module FIFO_fv();
    
    parameter WIDTH = 8;
    parameter DEPTH  = 16;
    parameter MAX_CNT = 3;
    localparam CNT_BITS = $clog2(MAX_CNT+1);

    logic                clock, reset;
    logic                wr_en;
    logic    [WIDTH-1:0] wr_data;
    logic                rd_en;
    logic    [WIDTH-1:0] rd_data;
    logic                rd_valid;
    logic                wr_valid;
    logic [CNT_BITS-1:0] spots;
    logic                full;

    // variable to count values written to FIFO
    int               cnt;

    // To speed up verification, make input data sequential 
    // and verify that output matches the same pattern
    int               wr_idx;
    int               rd_idx;

    // INSTANCE is from the sys_defs.svh file
    // it renames the module if SYNTH is defined in
    // order to rename the module to FIFO_svsim
    `INSTANCE(FIFO) #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .MAX_CNT(MAX_CNT))
    dut (
        .clock    (clock),
        .reset    (reset),
        .wr_en    (wr_en),
        .wr_data  (wr_data),
        .rd_en    (rd_en),
        .rd_data  (rd_data),
        .rd_valid (rd_valid),
        .wr_valid (wr_valid),
        .spots    (spots),
        .full     (full)
    );

    bind dut FIFO_sva #(
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .MAX_CNT(MAX_CNT)
    ) DUT_sva (.*);

    always_ff @(posedge clock) begin
        if (reset) begin
            cnt    <= 0;
            wr_idx <= 0;
            rd_idx <= 0;
        end else begin
            // Update how full FIFO is
            cnt <= cnt + (wr_valid && wr_en) -
                         (rd_valid && rd_en);
            // Track current count of writes and reads
            // This logic is just for making sure data in and data out follow the same
            // pattern. This logic doesn't need to be a sequential count
            if (wr_en && wr_valid) wr_idx <= wr_idx + 1;
            if (rd_en && rd_valid) rd_idx <= rd_idx + 1;
                         
        end
    end
        

    // Add additional covers
    // Cover all control signals
    cov_full    : cover property (@(posedge clock) full);
    cov_rd_vld  : cover property (@(posedge clock) rd_valid);
    cov_wr_vld  : cover property (@(posedge clock) wr_valid);
    
    // Write and read >DEPTH of fifo
    cov_wr_wrap : cover property (@(posedge clock) wr_en[->(DEPTH+1)]);
    cov_rd_wrap : cover property (@(posedge clock) rd_en[->(DEPTH+1)]);

    clocking cb @(posedge clock);

        property wr_data_matches_idx;
            wr_en && wr_valid |-> wr_data == wr_idx;
        endproperty

        property rd_data_matches_idx;
            rd_en && rd_valid |-> rd_data == rd_idx;
        endproperty

        // Liveness on inputs
        property eventually_rd;
            cnt == DEPTH |=> s_eventually rd_en;
        endproperty

        property retry_rd;
            rd_en && !rd_valid |=> s_eventually rd_en;
        endproperty;

        property eventually_wr;
            cnt == 0 |=> s_eventually wr_en;
        endproperty

        property retry_wr;
            wr_en && !wr_valid |=> s_eventually wr_en;
        endproperty;
    endclocking

    // Instead of formally verifying correct behavior,
    // Make inputs follow a pattern, and check output matches the same pattern
    // And add a cover to make sure every possible input bit is toggled
    CountIn:    assume property(cb.wr_data_matches_idx);
    CountOut:   assert property(cb.rd_data_matches_idx);

    // Assume liveness on en inputs
    RdEnLive : assume property(cb.eventually_rd);
    WrEnLive : assume property(cb.eventually_wr);
    RetryRd  : assume property(cb.retry_rd);
    RetryWr  : assume property(cb.retry_wr);


endmodule
