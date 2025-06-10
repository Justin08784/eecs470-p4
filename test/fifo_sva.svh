// SystemVerilog Assertions (SVA) for use with our FIFO module
// This file is included by the testbench to separate our main module checking code
// SVA are relatively new to 470, feel free to use them in the final project if you like

`ifndef FIFO_SVA_SVH
`define FIFO_SVA_SVH

module fifo_sva #(
    parameter int unsigned DEPTH,       // num elements
    parameter int unsigned WIDTH,       // num bits per element
    type FIFO_STATE = struct packed {
        logic [DEPTH-1:0][WIDTH-1:0] state;
        `IDX_TYPE(DEPTH) head, tail;
        `CNT_TYPE(DEPTH) free, used;
    },
    parameter int unsigned NUM_RPORTS, // also cap for used_scnt
    parameter int unsigned NUM_WPORTS, // also cap for free_scnt
    parameter logic ENABLE_INTR_FWD =`FALSE,
    parameter FIFO_STATE RESET_STATE = '{default:0}
) (
    // inputs
    input                                           clock, 
    input                                           reset,

    input   `CNT_TYPE(NUM_WPORTS) wr_en_cnt,
    input   `CNT_TYPE(NUM_WPORTS) free_scnt,
    input   logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data,

    input   `CNT_TYPE(NUM_RPORTS) rd_en_cnt,
    input   `CNT_TYPE(NUM_RPORTS) used_scnt,
    // outputs
    input   logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data

);
    struct packed {
        logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data;
        
        `CNT_TYPE(NUM_WPORTS) wr_en_cnt;
        `CNT_TYPE(NUM_RPORTS) rd_en_cnt;
    } ins_pre, ins_cur;

    struct packed {
        logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data;

        `CNT_TYPE(NUM_WPORTS) free_scnt;
        `CNT_TYPE(NUM_RPORTS) used_scnt;
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

    int unsigned rd_count; // number of reads complete
    logic [WIDTH-1:0] entries [$];
    int unsigned used; // how full the buffer should be
    int unsigned free; // "   free ""
        /* ^^ Use full 32-bit types to avoid overflow when we do arithmetic. */
    logic [NUM_RPORTS-1:0][WIDTH-1:0] rd_data_sva;
    assign free = DEPTH - used;
    // string s;

    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin
        // #0
        // for (int i = 0, string s; i < NUM_WPORTS; ++i) begin
        //     $display(wr_data[i]);
        //     s.itoa(wr_data[i]);
        //     $display("wr_dat[%d]: %s", i, i < wr_en_cnt ? s : "f");
        // end
        // for (int i = 0, string s; i < NUM_RPORTS; ++i) begin
        //     s.itoa(rd_data[i]);
        //     $display("rd_dat[%d]: %d", i, i < rd_en_cnt ? s : "f");
        // end
        for (int i = 0; i < wr_en_cnt; ++i) begin
            entries.push_back(wr_data[i]);
        end

        rd_data_sva = '0;
        for (int i = 0; i < `MIN(used + wr_en_cnt, NUM_RPORTS); ++i) begin
            rd_data_sva[i] = entries[i];
        end
        for (int i = 0; i < rd_en_cnt; ++i) begin
            entries.pop_front();
        end
        // #0
        @(posedge clock);
        @(negedge clock);
    end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            rd_count    <= 0;
            used        <= RESET_STATE.used;
            entries.delete();
            for (int i = 0; i < RESET_STATE.used; ++i) begin
                entries.push_back(RESET_STATE.state[(RESET_STATE.head + i) % DEPTH]);
            end

            // entries_pre <= '0;
            ins_pre     <= '0;
            outs_pre    <= '0;
        end else begin
            rd_count    <= rd_count + rd_en_cnt;
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
            rd_en_cnt <= used + wr_en_cnt;
        endproperty

        property wr_en_correct;
            disable iff (reset)
            wr_en_cnt <= free + rd_en_cnt;
        endproperty

        property used_scnt_correct;
            disable iff (reset)
            used_scnt == (ENABLE_INTR_FWD
                ? `MIN(used + wr_en_cnt, `UCAST_FIT(NUM_RPORTS))
                : `MIN(used, NUM_RPORTS));
        endproperty

        property free_scnt_correct;
            disable iff (reset)
            free_scnt == free < NUM_WPORTS ? free : NUM_WPORTS;
        endproperty

        property rd_data_correct;
            disable iff (reset)
            rd_data == rd_data_sva;
        endproperty

        property write_read_correctly(i);
            logic [WIDTH-1:0] data_in;
            int               idx;
            (wr_en_cnt > i, data_in=wr_data[i], idx=(rd_count + used + i)) // value is written
            ##[0:$] (rd_en_cnt > 0 && rd_count <= idx && idx < rd_count + rd_en_cnt) // wait for previous entries to be read
            |-> rd_data[idx - rd_count] === data_in;              // ensure correct value out
        endproperty

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
    generate
        for (genvar wr_port = 0; wr_port < NUM_WPORTS; ++wr_port) begin : gen_wr_props
            assert property(cb.write_read_correctly(wr_port))
                else exit_on_error;
        end
    endgenerate
  

endmodule

`endif // FIFO_SVA_SVH
