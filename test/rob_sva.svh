`ifndef ROB_SVA_SVH
`define ROB_SVA_SVH

module rob_sva #(
    parameter ROB_SZ = `ROB_SZ,  // num elements
    parameter N=`N
) (
    `ifdef DEBUG
    input ROB_ENTRY   [ROB_SZ-1:0]    state_dbg,
    `endif

    input                       clock, reset,

    // retire (read)
    input rob2retire r_out,

    // complete (write)
    input complete2rob c_in,

    // dispatch (write)
    input rob2dispatch d_out,
    input dispatch2rob d_in
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)

    int                        r_count; // number of reads/retires complete
    int wr_idx = 0;
    logic cpls[int]; // idx to cpl
    struct packed {
        int idx;
        logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] tag;
        logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] t_old;
    } entries [$], tmp_entry;

    logic [$clog2(ROB_SZ):0] used;    // how full the buffer should be
    logic [$clog2(ROB_SZ):0] free;    // how full the buffer should be
    assign free = ROB_SZ - used;

    struct packed {
        logic [$clog2(N):0]     r_en_cnt;

        PHYS_REG_IDX [N-1:0]    tag;
        PHYS_REG_IDX [N-1:0]    t_old;
    } r_out_sva;
    struct packed {
        logic [$clog2(N):0]     rob_rdy_scnt;
            // To: dispatch
            // saturating counter for number of free rob entries
        ROB_IDX [N-1:0]         rob_idxs;
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
            if (!cpls[tmp_entry.idx])
                break;
            
            r_out_sva.tag[i] = tmp_entry.tag;
            r_out_sva.t_old[i] = tmp_entry.t_old;
            cpls.delete(tmp_entry.idx);
            entries.pop_front();
        end

        d_out_sva.rob_rdy_scnt = `MIN(free, NUM_DPORTS);
        foreach (d_out_sva.rob_idxs[i])
            d_out_sva.rob_idxs[i] = (wr_idx + i) % ROB_SZ;

        // #0
        for (int i = 0; i < d_in.d_en_cnt; ++i) begin
            entries.push_back('{
                idx:wr_idx,
                tag:d_in.tag[i],
                t_old:d_in.t_old[i]
            });
            cpls[wr_idx] = 0;
            wr_idx = (wr_idx + 1) % ROB_SZ;
        end

        for (int i = 0; i < c_in.c_en; ++i)
            cpls[c_in.c_rob_idxs[i]] |= c_in.c_en[i];

        @(posedge clock);
        // for (int i = 0; i < `MIN(ROB_SZ, 10); ++i) begin
        //     $display("rob[%d]: (t: %d, t_old: %d, cpl: %b)", i, state_dbg[i].tag, state_dbg[i].t_old, state_dbg[i].cpl);
        // end
        @(negedge clock);
    end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            r_count <= 0;
            used <= 0;
            cpls.delete();
            entries.delete();
        end else begin
            r_count <= r_count + r_out.r_en_cnt;
            used <= entries.size;
        end
    end

    task exit_on_error;
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            for (int i = 0; i < N; ++i) begin
                $display("r_out[%d]: (%d, %d)", i, r_out.tag[i], r_out.t_old[i]);
            end
            for (int i = 0; i < N; ++i) begin
                $display("r_out_sva[%d]: (%d, %d)", i, r_out_sva.tag[i], r_out_sva.t_old[i]);
            end

            $display("d_out.rob_rdy_scnt: %d", d_out.rob_rdy_scnt);
            $display("d_out_sva.rob_rdy_scnt: %d", d_out.rob_rdy_scnt);
            for (int i = 0; i < N; ++i) begin
                $display("d_out.rob_idxs[%d]: %d", i, d_out.rob_idxs[i]);
            end
            for (int i = 0; i < N; ++i) begin
                $display("d_out_sva.rob_idxs[%d]: %d", i, d_out_sva.rob_idxs[i]);
            end
            $display("d_out:%b", d_out);
            $display("d_out_sva:%b", d_out_sva);
            $display("used %d free %d reset: %b", used, free, reset);
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        property r_en_correct;
            disable iff (reset)
            r_out.r_en_cnt <= used + d_in.d_en_cnt;
        endproperty

        property d_en_correct;
            disable iff (reset)
            d_in.d_en_cnt <= free + r_out.r_en_cnt;
        endproperty

        // property used_scnt_correct;
        //     disable iff (reset)
        //     used_scnt == used < NUM_RPORTS ? used : NUM_RPORTS;
        // endproperty

        // property free_scnt_correct;
        //     disable iff (reset)
        //     free_scnt == free < NUM_WPORTS ? free : NUM_WPORTS;
        // endproperty

        property r_out_correct;
            disable iff (reset)
            r_out == r_out_sva;
        endproperty

        property d_out_correct;
            disable iff (reset)
            d_out == d_out_sva;
        endproperty
        
        property dispatch_complete_retire(i);
            // Step 1) Dispatch
            logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] tag_in;
            logic [$clog2(`PHYS_REG_SZ_R10K)-1:0] t_old_in;
            int idx_in; 
            int cnt_idx; (
                d_in.d_en_cnt > i,
                idx_in = d_out.rob_idxs[i],
                cnt_idx= (r_count + used + i),
                tag_in = d_in.tag[i],
                t_old_in = d_in.t_old[i]
            )
            // Step 2) eventually Complete
            ##[1:$] (
                |(c_in.c_en & (c_in.c_rob_idxs == idx_in))
            )
            // Step 3) eventually Retire
            ##[1:$] (
                // We know the design retires in order, so the item at rob index = idx_in
                // will eventually appear in r_out.*some slot* EXACTLY once all prior
                // entries are retired + it's completed. Checking that it *does* appear:
                (r_out.r_en_cnt > i && r_count <= cnt_idx && cnt_idx < r_count + r_out.r_en_cnt)
                // r_out.r_en_cnt > 0
                // &&  // We want to see if *some* slot `j` in r_out matches (tag_in, t_old_in).
                //     // Usually you'd do something like:
                //     ( (r_out.tag[0]   == tag_in && r_out.t_old[0]   == t_old_in)
                //     || (r_out.tag[1]   == tag_in && r_out.t_old[1]   == t_old_in))
            )
            |-> (r_out.tag[cnt_idx - r_count] === tag_in) && (r_out.t_old[cnt_idx - r_count] === t_old_in);
            // $display("OK: dispatch %0d completed+retired", idx_in); 
            // or do a final check that they match, or simply succeed silently
        endproperty

        property retire_head_only(i);
            // An insn can retire only if its rob_idx is in [head, (head + r_en_cnt - 1) % ROB_SIZE]
            int cnt_idx; (
                d_in.d_en_cnt > i,
                cnt_idx= (r_count + used + i)
            ) ##[1:$] (
                1
                // ??
            ) |-> 1;
        endproperty

        property no_early_retire(i);
            // An insn can retire ONLY IF it has already completed.
            disable iff (reset)
            // “If the design is retiring slot i this cycle, then cpl must be set in state[]”
            1;
            // (i < r_out.r_en_cnt) |-> state[r_idxs[i]].cpl;
            // ??
        endproperty
    endclocking

    // Assert properties
    REn: assert property(cb.r_en_correct)
        else exit_on_error;
    WEn: assert property(cb.d_en_correct)
        else exit_on_error;
    // UsedScnt: assert property(cb.used_scnt_correct)
    //     else exit_on_error;
    // FreeScnt: assert property(cb.free_scnt_correct)
    //     else exit_on_error;
    ROut: assert property(cb.r_out_correct)
        else exit_on_error;
    DOut: assert property(cb.d_out_correct)
        else exit_on_error;
    // NoEarlyRetire: assert property(cb.no_early_retire)
    //     else exit_on_error;
    generate
        for (genvar i = 0; i < NUM_DPORTS; ++i) begin : gen_dcrs
            DCR_i: assert property(cb.dispatch_complete_retire(i))
                else exit_on_error;
        end
    endgenerate

endmodule

`endif // ROB_SVA_SVH