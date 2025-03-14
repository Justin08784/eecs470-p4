`include "sys_defs.svh"


/* 
================================================
Map Table
================================================
*/
// Comments:
// - should be declared as a submodule of dispatch eh? doesnt seem anyone
// else references it...?
// - map table is more complicated than a simple lookup. forall i < j,
// src1s[j], src2s[j] may potentially be dsts[i]. i.e. there is a serial dependency
module map_table #(parameter 
    N=`N
) (
    input clock, reset,
    // retire ??

    // complete
    input struct packed {
        logic         [N-1:0] c_en;
            // - Enabled complete lines?
        PHYS_REG_IDX  [N-1:0] c_ts; // tags
            // From: complete (EX)
    } c_in,

    // issue ??

    // dispatch
    input struct packed {
        logic         [$clog2(N):0] en_cnt;
            // - Number of enabled dispatch lines?
            // - NOTE: For in-order stuff with serial deps (like dispatch), use c(ou)nts;
            // otherwise use en(able) buses.
        REG_IDX       [N-1:0] src1s;
        REG_IDX       [N-1:0] src2s;
        REG_IDX       [N-1:0] dsts;
        PHYS_REG_IDX  [N-1:0] ts;
            // From: dispatch
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } d_in,
    output struct packed {
        logic        [N-1:0] cpl1s;
        logic        [N-1:0] cpl2s;
            // To: dispatch
            // - src1s, src2s is_complete bits resp.
        PHYS_REG_IDX [N-1:0] t1s;
            // To: dispatch
            // - Renamed physical registers tags for src1s
            // - src1[i] -> t1[i]
        PHYS_REG_IDX [N-1:0] t2s;
            // To: dispatch
            // - Renamed physical registers tags for src2s
            // - src2[i] -> t2[i]
    } rs_out
);
    localparam NUM_ARCH_REG = 32;
    struct packed {
        PHYS_REG_IDX t;
        logic cpl;
    } [NUM_ARCH_REG-1:0] entries, entries_n;

    always_comb begin
        entries_n = entries;
        // handle completes
        for (int i = 0; i < N; ++i) begin
            /* Checking for preg#0 is presumably not necessary since it cannot
            be allocated as a dest reg. */
            // if (!c_in.c_en[i] || c_in.c_ts[i] == `0)
            //     continue;
            if (!c_in.c_en[i])
                continue;
            for (int r = 0; r < NUM_ARCH_REG; ++r) begin  // Loop over architectural registers
                if (entries_n[r].t == c_in.c_ts[i]) begin
                    $display("DEBUG: Completing reg[%0d] because t = %0d matches c_ts[%0d] = %0d", r, entries_n[r].t, i, c_in.c_ts[i]);
                    entries_n[r].cpl = 1;  // ✅ Mark as completed
                    rs_out.cpl1s[i]  = entries_n[r].cpl;
                   // break;  // ✅ Stop checking once we've found the match
                end else begin
                    $display("DEBUG: Not Completing reg[%0d]  t = %0d  c_ts[%0d] = %0d, %0d", r, entries_n[r].t, i, c_in.c_ts[i], entries_n[r].cpl);
                end
            end

          //  rs_out.cpl1s[i]  = entries_n[d_in.src1s[i]].cpl;
           // rs_out.cpl2s[i]  = entries_n[d_in.src2s[i]].cpl;

        end

        // handle renames
        for (int i = 0; i < d_in.en_cnt; ++i) begin
            $display("DEBUG: Dispatching - dsts[%0d] = %0d, new tag = %0d", i, d_in.dsts[i], d_in.ts[i]);
            /*
            Idea: how about we always map ZERO_REG -> preg #0, cpl=1,
            and it cannot be edited?
            */

            

            //rs_out.t1s[i]    = entries_n[d_in.src1s[i]].t;

            if (d_in.dsts[i] != `ZERO_REG) begin
                entries_n[d_in.dsts[i]].t   = d_in.ts[i];
                entries_n[d_in.dsts[i]].cpl = 0;
                $display("DEBUG: Set entries[%0d] -> t = %0d, cpl = %0b", d_in.dsts[i], d_in.ts[i], entries_n[d_in.dsts[i]].cpl);
            end else begin
                entries_n[d_in.dsts[i]].t   = 0;
                entries_n[d_in.dsts[i]].cpl = 1;
                $display("DEBUG: entries[0].t at cycle %0t = %0d", $time, entries[0].t);
            end

           

            if (d_in.dsts[i] != `ZERO_REG) begin
                rs_out.t1s[i]    = entries_n[d_in.src1s[i]].t;
                rs_out.t2s[i]    = entries_n[d_in.src2s[i]].t;
                rs_out.cpl1s[i]  = entries_n[d_in.src1s[i]].cpl;
                rs_out.cpl2s[i]  = entries_n[d_in.src2s[i]].cpl;

                $display("DEBUG: rs_out.cpl1s[%0d] = %0d (entries[%0d].cpl = %0d)", i, rs_out.cpl1s[i], d_in.src1s[i], entries_n[d_in.src1s[i]].cpl);
                $display("DEBUG: rs_out.cpl2s[%0d] = %0d (entries[%0d].cpl = %0d)", i, rs_out.cpl2s[i], d_in.src2s[i], entries_n[d_in.src2s[i]].cpl);
            end else begin
                rs_out.t1s[i]    = 0;
                rs_out.t2s[i]    = 0;
                rs_out.cpl1s[i]  = 1;
                rs_out.cpl2s[i]  = 1;
                $display("DEBUG: rs_out.cpl1s[%0d] = %0d (entries[%0d].cpl = %0d)", i, rs_out.cpl1s[i], d_in.src1s[i], entries_n[d_in.src1s[i]].cpl);
                $display("DEBUG: rs_out.cpl2s[%0d] = %0d (entries[%0d].cpl = %0d)", i, rs_out.cpl2s[i], d_in.src2s[i], entries_n[d_in.src2s[i]].cpl);

            end

            

          /*  if (d_in.src2s[i] == `ZERO_REG) begin
                rs_out.t2s[i] = 0;
            end else begin
                rs_out.t2s[i] = entries_n[d_in.src2s[i]].t;
            end*/

        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int r = 1; r < NUM_ARCH_REG; ++r) begin
                entries[r].t = r;  // ✅ Map PRx = Rx (Arch Reg x → PRx)
                entries[r].cpl = 1; // Mark all as initially completed
            end
            entries[`ZERO_REG] = '{t: '0, cpl: 1}; // Ensure ZERO_REG always maps to PR0
        end else begin
            entries <= entries_n;
            if (entries[`ZERO_REG].t != 0) begin
                $error("❌ ERROR: entries[0].t was modified! Got: %0d", entries[`ZERO_REG].t);
            end
        end
    end
endmodule
