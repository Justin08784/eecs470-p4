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
    // inputs
    input                                           clock, 
    input                                           reset,

    input   logic   [$clog2(NUM_WPORTS):0]          wr_en_cnt,
    input   logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data,

    input   logic   [$clog2(NUM_RPORTS):0]          rd_en_cnt,
    // outputs
    input   logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data,

    input   logic   [$clog2(MAX_SCNT):0]            free_scnt,
    input   logic   [$clog2(MAX_SCNT):0]            used_scnt
);
    struct packed {
        logic   [$clog2(NUM_WPORTS):0]          wr_en_cnt;
        logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data;

        logic   [$clog2(NUM_RPORTS):0]          rd_en_cnt;
    } ins_pre, ins_cur;

    struct packed {
        logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data;

        logic   [$clog2(MAX_SCNT):0]            free_scnt;
        logic   [$clog2(MAX_SCNT):0]            used_scnt;
    } outs_pre, outs_cur;

    assign ins_cur = '{
        wr_en_cnt:wr_en_cnt,
        wr_data:wr_data,
        rd_en_cnt:rd_en_cnt
    };

    assign outs_cur = '{
        rd_data:rd_data,
        free_scnt:free_scnt,
        used_scnt:used_scnt
    };

    logic [WIDTH-1:0] entries [$];
    logic [$clog2(DEPTH):0] used;    // how full the buffer should be
    logic [$clog2(DEPTH):0] free;    // how full the buffer should be
    logic [NUM_RPORTS-1:0][WIDTH-1:0] rd_data_sva;
    assign free = DEPTH - used;

    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin
        for (int i = 0; i < wr_en_cnt; ++i) begin
            entries.push_back(wr_data[i]);
        end

        rd_data_sva = '0;
        for (int i = 0; i < rd_en_cnt; ++i) begin
            rd_data_sva[i] = entries.pop_front();
        end
        // #0
        @(posedge clock);
        @(negedge clock);
    end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            used        <= RESET_STATE.used;
            entries.delete();
            for (int i = 0; i < RESET_STATE.used; ++i) begin
                entries.push_back(RESET_STATE.state[(RESET_STATE.head + i) % DEPTH]);
            end

            // entries_pre <= '0;
            ins_pre     <= '0;
            outs_pre    <= '0;
        end else begin
            used        <= entries.size;
            // entries_pre <= entries_cur;

            ins_pre     <= ins_cur;
            outs_pre    <= outs_cur;
        end
    end

    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            $display("used %d free %d us %d fs %d reset: %b", used, free, used_scnt, free_scnt, reset);
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        property rd_en_correct;
            disable iff (reset)
            rd_en_cnt <= used;
        endproperty

        property wr_en_correct;
            disable iff (reset)
            wr_en_cnt <= free;
        endproperty

        property used_scnt_correct;
            disable iff (reset)
            used_scnt == used < MAX_SCNT ? used : MAX_SCNT;
        endproperty

        property free_scnt_correct;
            disable iff (reset)
            free_scnt == free < MAX_SCNT ? free : MAX_SCNT;
        endproperty

        property rd_data_correct;
            disable iff (reset)
            rd_data == rd_data_sva;
        endproperty



        // // rd_valid asserted if and only if rd_en=1 and there is valid data
        // property rd_valid_correct;
        //     rd_valid_c iff rd_valid;
        // endproperty

        // // wr_valid asserted if and only if wr_en=1 and buffer not full
        // property wr_valid_correct;
        //     wr_valid_c iff wr_valid;
        // endproperty

        // // full asserted if and only if buffer is full
        // property full_correct;
        //     full iff used == DEPTH;
        // endproperty

        // // almost full signal asserted when there are ALERT_DEPTH used left
        // property spots_correct;
        //     disable iff (reset)
        //     spots == (used < (DEPTH-MAX_CNT) ? MAX_CNT : DEPTH - used);
        // endproperty

        // // Check that data written in comes out after proper number of reads
        // // NOTE: this property isn't used in verification as it runs slowly
        // //      However, feel free to reference as an example of a more
        // //      complex assertion
        // property write_read_correctly;
        //     logic [WIDTH-1:0] data_in;
        //     int               idx;
        //     (wr_valid, data_in=wr_data, idx=(rd_count+used)) // value is written
        //     ##[1:$] (rd_valid && rd_count == idx) // wait for previous used to be read
        //     |-> rd_data === data_in;              // ensure correct value out
        // endproperty

        // property rd_valid_live;
        //     rd_en |-> s_eventually rd_valid;
        // endproperty

        // property wr_valid_live;
        //     wr_en |-> s_eventually wr_valid;
        // endproperty

    endclocking

    // Assert properties
    RdEn: assert property(cb.rd_en_correct)
        else exit_on_error;
    WrEn: assert property(cb.wr_en_correct)
        else exit_on_error;
    UsedScnt: assert property(cb.used_scnt_correct)
        else exit_on_error;
    FreeScnt: assert property(cb.free_scnt_correct)
        else exit_on_error;
    RdData: assert property(cb.rd_data_correct)
        else exit_on_error;
    // ValidRd:    assert property(cb.rd_valid_correct)     else exit_on_error;
    // ValidWr:    assert property(cb.wr_valid_correct)     else exit_on_error;
    // ValidFull:  assert property(cb.full_correct)         else exit_on_error;
    // ValidSpots: assert property(cb.spots_correct)        else exit_on_error;

    // Liveness checks
    // RdValidLiveness: assert property(cb.rd_valid_live)   else exit_on_error;
    // WrValidLiveness: assert property(cb.wr_valid_live)   else exit_on_error;

    // This assertion is large and slow for formal verification, 
    // but it works for a testbench
    // DataOutErr: assert property(cb.write_read_correctly) else exit_on_error;

    // genvar i;
    // generate 
    //     for (i = 0; i < WIDTH; i++) begin
    //         cov_bit_i:  cover property(@(posedge clock) wr_data[i]);
    //     end
    // endgenerate
    

endmodule

`endif // FIFO_SVA_SVH
