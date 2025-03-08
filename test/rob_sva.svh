`ifndef ROB_SVA_SVH
`define ROB_SVA_SVH

module rob_sva #(
    parameter DEPTH = `ROB_SZ,  // num elements
    parameter WIDTH = $bits(ROB_ENTRY),  // num bits per element 
                           //(32 bits per insn + log2(64) = 6 bits each for T & Told)
    parameter N=`N
) (
    input                       clock, reset,

    // retire (read)
    input struct packed {
        logic [$clog2(N):0]     r_en_cnt;


        PHYS_REG_IDX [N-1:0]    tag;
        PHYS_REG_IDX [N-1:0]    t_old;
    } r_out,

    // complete (write)
    input struct packed {
        logic [N-1:0]           c_en;
            // - From: EX
        ROB_IDX [N-1:0]         c_rob_idxs;
            // - From: EX
    } c_in,

    // dispatch (write)
    input struct packed {
        logic [$clog2(N):0]     rob_rdy_scnt;
            // To: dispatch
            // saturating counter for number of free rob entries
    } d_out,
    input struct packed {
        logic [$clog2(N):0]     d_en_cnt;
            // From: dispatch
            // - Number of enabled dispatch lines?
        ROB_ENTRY   [N-1:0]     d_dat;
            // From: dispatch
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } d_in
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)

    int wr_idx = 0;
    logic cpls_sva[int]; // idx to cpl
    struct packed {
        int idx;
        ROB_ENTRY dat;
    } entries [$], tmp_entry;

    logic [$clog2(DEPTH):0] used;    // how full the buffer should be
    logic [$clog2(DEPTH):0] free;    // how full the buffer should be
    logic [NUM_RPORTS-1:0][WIDTH-1:0] rd_data_sva;
    assign free = DEPTH - used;

    struct packed {
        logic [$clog2(N):0]     r_en_cnt;

        PHYS_REG_IDX [N-1:0]    tag;
        PHYS_REG_IDX [N-1:0]    t_old;
    } r_out_sva;
    struct packed {
        logic [$clog2(N):0]     rob_rdy_scnt;
            // To: dispatch
            // saturating counter for number of free rob entries
    } d_out_sva;

    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin
        r_out_sva = '0;
        for (int i = 0; i < NUM_RPORTS; ++i, ++r_out_sva.r_en_cnt) begin
            if (i >= entries.size())
                break;

            tmp_entry = entries[i];
            if (!cpls_sva[tmp_entry.idx])
                break;
            
            r_out_sva.tag[i] = tmp_entry.dat.tag;
            r_out_sva.t_old[i] = tmp_entry.dat.tag;
            cpls_sva.delete(tmp_entry.idx);
            entries.pop_front();
        end

        // #0
        for (int i = 0; i < d_in.d_en_cnt; ++i) begin
            entries.push_back('{
                idx:wr_idx,
                dat:d_in.d_dat[i]
            });
            cpls_sva[wr_idx] = 0;
            wr_idx = (wr_idx + 1) % DEPTH;
        end

        for (int i = 0; i < c_in.c_en; ++i)
            cpls_sva[c_in.c_rob_idxs[i]] |= c_in.c_en[i];

        @(posedge clock);
        @(negedge clock);
    end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            used <= 0;
            cpls_sva.delete();
            entries.delete();
        end else begin
            used <= entries.size;
        end
    end

    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            $display("used %d free %d reset: %b", used, free, reset);
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        // property rd_en_correct;
        //     disable iff (reset)
        //     rd_en_cnt <= used + wr_en_cnt;
        // endproperty

        // property wr_en_correct;
        //     disable iff (reset)
        //     wr_en_cnt <= free + rd_en_cnt;
        // endproperty

        // property used_scnt_correct;
        //     disable iff (reset)
        //     used_scnt == used < NUM_RPORTS ? used : NUM_RPORTS;
        // endproperty

        // property free_scnt_correct;
        //     disable iff (reset)
        //     free_scnt == free < NUM_WPORTS ? free : NUM_WPORTS;
        // endproperty

        // property rd_data_correct;
        //     disable iff (reset)
        //     rd_data == rd_data_sva;
        // endproperty
    endclocking

    // Assert properties
    // RdEn: assert property(cb.rd_en_correct)
    //     else exit_on_error;
    // WrEn: assert property(cb.wr_en_correct)
    //     else exit_on_error;
    // UsedScnt: assert property(cb.used_scnt_correct)
    //     else exit_on_error;
    // FreeScnt: assert property(cb.free_scnt_correct)
    //     else exit_on_error;
    // RdData: assert property(cb.rd_data_correct)
    //     else exit_on_error;

endmodule

`endif // ROB_SVA_SVH