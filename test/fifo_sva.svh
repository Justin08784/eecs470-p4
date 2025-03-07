// SystemVerilog Assertions (SVA) for use with our FIFO module
// This file is included by the testbench to separate our main module checking code
// SVA are relatively new to 470, feel free to use them in the final project if you like

`ifndef FIFO_SVA_SVH
`define FIFO_SVA_SVH

module fifo_sva #(
    parameter int unsigned DEPTH,       // num elements
    parameter int unsigned WIDTH,       // num bits per element
    type FIFO_STATE = struct packed {
        logic [$clog2(DEPTH)-1:0] head;
        logic [$clog2(DEPTH)-1:0] tail;
        logic [DEPTH-1:0][WIDTH-1:0] state;
        logic [$clog2(DEPTH):0]   used;
        // logic [$clog2(DEPTH):0]   free;
    },
    parameter int unsigned NUM_RPORTS,
    parameter int unsigned NUM_WPORTS,
    parameter int unsigned MAX_SCNT,    // should be less than DEPTH
    parameter FIFO_STATE RESET_STATE = '{default:0}
) (
    input                                           clock, 
    input                                           reset,

    input   logic   [$clog2(NUM_WPORTS):0]          wr_en_cnt,
    input   logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data,

    input   logic   [$clog2(NUM_RPORTS):0]          rd_en_cnt,
    output  logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data,

    output  logic   [$clog2(MAX_SCNT):0]            free_scnt,
    output  logic   [$clog2(MAX_SCNT):0]            used_scnt
);

    logic [$clog2(DEPTH+1)-1:0] entries;    // how full the buffer should be
    int                        rd_count;   // number of reads complete

    logic rd_valid_c, wr_valid_c;

    assign rd_valid_c = rd_en && (entries != 0);
    assign wr_valid_c = wr_en && (entries != DEPTH || rd_en);

    always_ff @(posedge clock) begin
        if (reset) begin
            entries <= 0;
            rd_count <= 0;
        end else begin
            entries <= entries +
                       (wr_en && entries != DEPTH ? 1-rd_valid_c : 0) -
                       (rd_en && entries != 0    ? 1-wr_valid_c : 0);
            rd_count <= rd_valid ? rd_count+1 : rd_count;
        end
    end

    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        // rd_valid asserted if and only if rd_en=1 and there is valid data
        property rd_valid_correct;
            rd_valid_c iff rd_valid;
        endproperty

        // wr_valid asserted if and only if wr_en=1 and buffer not full
        property wr_valid_correct;
            wr_valid_c iff wr_valid;
        endproperty

        // full asserted if and only if buffer is full
        property full_correct;
            full iff entries == DEPTH;
        endproperty

        // almost full signal asserted when there are ALERT_DEPTH entries left
        property spots_correct;
            disable iff (reset)
            spots == (entries < (DEPTH-MAX_CNT) ? MAX_CNT : DEPTH - entries);
        endproperty

        // Check that data written in comes out after proper number of reads
        // NOTE: this property isn't used in verification as it runs slowly
        //      However, feel free to reference as an example of a more
        //      complex assertion
        property write_read_correctly;
            logic [WIDTH-1:0] data_in;
            int               idx;
            (wr_valid, data_in=wr_data, idx=(rd_count+entries)) // value is written
            ##[1:$] (rd_valid && rd_count == idx) // wait for previous entries to be read
            |-> rd_data === data_in;              // ensure correct value out
        endproperty

        property rd_valid_live;
            rd_en |-> s_eventually rd_valid;
        endproperty

        property wr_valid_live;
            wr_en |-> s_eventually wr_valid;
        endproperty

    endclocking

    // Assert properties
    ValidRd:    assert property(cb.rd_valid_correct)     else exit_on_error;
    ValidWr:    assert property(cb.wr_valid_correct)     else exit_on_error;
    ValidFull:  assert property(cb.full_correct)         else exit_on_error;
    ValidSpots: assert property(cb.spots_correct)        else exit_on_error;

    // Liveness checks
    RdValidLiveness: assert property(cb.rd_valid_live)   else exit_on_error;
    WrValidLiveness: assert property(cb.wr_valid_live)   else exit_on_error;

    // This assertion is large and slow for formal verification, 
    // but it works for a testbench
    DataOutErr: assert property(cb.write_read_correctly) else exit_on_error;

    genvar i;
    generate 
        for (i = 0; i < WIDTH; i++) begin
            cov_bit_i:  cover property(@(posedge clock) wr_data[i]);
        end
    endgenerate
    

endmodule

`endif // FIFO_SVA_SVH
