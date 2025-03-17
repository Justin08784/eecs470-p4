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
    input execute2complete c_in,

    // issue ??

    // dispatch
    input dispatch2map_table d_in,
    output map_table2dispatch d_out
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
            for (int r = 0; r < NUM_ARCH_REG; ++r) begin
                // $display("DEBUG: Completing reg[%0d] because t = %0d matches c_ts[%0d] = %0d", r, entries_n[r].t, i, c_in.c_ts[i]);
                // $display("DEBUG: Not Completing reg[%0d]  t = %0d  c_ts[%0d] = %0d, %0d", r, entries_n[r].t, i, c_in.c_ts[i], entries_n[r].cpl);
                entries_n[r].cpl |= (entries_n[r].t == c_in.c_ts[i]);
            end
        end

        // handle renames
        for (int i = 0; i < d_in.en_cnt; ++i) begin
            // $display("DEBUG: Dispatching - dsts[%0d] = %0d, new tag = %0d", i, d_in.dsts[i], d_in.ts[i]);
            /*
            Idea: how about we always map ZERO_REG -> preg #0, cpl=1,
            and it cannot be edited?
            */
            // $display("DEBUG: d_out.cpl1s[%0d] = %0d (entries[%0d].cpl = %0d)", i, d_out.cpl1s[i], d_in.src1s[i], entries_n[d_in.src1s[i]].cpl);
            // $display("DEBUG: d_out.cpl2s[%0d] = %0d (entries[%0d].cpl = %0d)", i, d_out.cpl2s[i], d_in.src2s[i], entries_n[d_in.src2s[i]].cpl);
            d_out.t1s[i]    = entries_n[d_in.src1s[i]].t;
            d_out.t2s[i]    = entries_n[d_in.src2s[i]].t;
            d_out.cpl1s[i]  = entries_n[d_in.src1s[i]].cpl;
            d_out.cpl2s[i]  = entries_n[d_in.src2s[i]].cpl;

            if (d_in.dsts[i] != `ZERO_REG) begin
                // $display("DEBUG: Set entries[%0d] -> t = %0d, cpl = %0b", d_in.dsts[i], d_in.ts[i], entries_n[d_in.dsts[i]].cpl);
                // $display("DEBUG: entries[0].t at cycle %0t = %0d", $time, entries[0].t);
                entries_n[d_in.dsts[i]].t   = d_in.ts[i];
                entries_n[d_in.dsts[i]].cpl = 0;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int r = 1; r < NUM_ARCH_REG; ++r) begin
                entries[r].t    <= r;   // ✅ Map PRx = Rx (Arch Reg x → PRx)
                entries[r].cpl  <= 1;   // Mark all as initially completed
            end
            entries[`ZERO_REG]  <= '{
                t: '0,
                cpl: 1
            }; // Ensure ZERO_REG always maps to PR0
        end else begin
            entries <= entries_n;
            if (entries[`ZERO_REG].t != '0 || !entries[`ZERO_REG].cpl) begin
                $error("ERROR: entries[0] was modified! Got: {t:%0d, cpl:%b}", 
                    entries[`ZERO_REG].t,
                    entries[`ZERO_REG].cpl
                );
            end
        end
    end

endmodule
