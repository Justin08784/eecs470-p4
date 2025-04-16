`include "sys_defs.svh"

module branch_history_table (
    input  logic clock,
    input  logic reset,

    // Fetch stage: read BHR for prediction
    input  ADDR fetch_PC0,
    input  ADDR fetch_PC1,

    // Retire stage: update BHR
    input  logic         update_enable0,
    input  logic         update_enable1,
    input  logic [7:0]   update_PC0,
    input  logic [7:0]   update_PC1,
    input  logic         taken0,
    input  logic         taken1,

    output logic [`HISTORY_BITS-1:0] bhr0,
    output logic [`HISTORY_BITS-1:0] bhr1,


    output logic [7:0] table_index0,
    output logic [7:0] table_index1
);
    logic [`BHT_ENTRIES-1:0][`HISTORY_BITS-1:0] table_array;

    logic [$clog2(`BHT_ENTRIES)-1:0] fetch_idx0, fetch_idx1, update_idx0, update_idx1;

    assign fetch_idx0  = fetch_PC0;
    assign fetch_idx1  = fetch_PC1;
    assign update_idx0 = update_PC0;
    assign update_idx1 = update_PC1;

    assign bhr0 = table_array[fetch_idx0];
    assign bhr1 = table_array[fetch_idx1];


    assign table_index0 = {table_array[update_idx0][`HISTORY_BITS-2:0], taken0};
    assign table_index1 = {table_array[update_idx1][`HISTORY_BITS-2:0], taken1};

    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            foreach (table_array[i])
               table_array[i] <= '0;
        end else begin
            if (update_enable0)
                table_array[update_idx0] <= {table_array[update_idx0][`HISTORY_BITS-2:0], taken0};
            if (update_enable1)
               table_array[update_idx1] <= {table_array[update_idx1][`HISTORY_BITS-2:0], taken1};
        end

       //  $display("  BHR0 0b%8b TAKEN0: 0b%1b ", bhr0, taken0);
       //  $display("  BHR0 0b%8b TAKEN1: 0b%1b ", bhr1, taken1);
    end
endmodule
