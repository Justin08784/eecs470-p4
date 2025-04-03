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
// TODO: implement internal forwarding ala fifo.sv?
module map_table #(parameter 
    N=`N
) (
    input clock, reset, flush,

    `ifdef DEBUG
    output struct packed {
        PHYS_REG_IDX t;
    } [`NUM_ARCH_REG-1:0] entries_dbg,
    `endif

    // flush
    input arch_map2map_table am_in,

    // retire ??

    // complete

    // issue ??

    // dispatch
    input dispatch2map_table d_in,
    output map_table2dispatch d_out
);
    struct packed {
        PHYS_REG_IDX t;
    } [`NUM_ARCH_REG-1:0] entries, entries_n;
    `ifdef DEBUG
    assign entries_dbg = entries;
    `endif

    always_comb begin
        entries_n = entries;
        d_out = '0;

        // handle renames
        for (int i = 0; i < d_in.en_cnt; ++i) begin
            /*
            Idea: how about we always map ZERO_REG -> preg #0, cpl=1,
            and it cannot be edited?
            */
            d_out.t1s[i]    = entries_n[d_in.src1s[i]].t;
            d_out.t2s[i]    = entries_n[d_in.src2s[i]].t;

            if (d_in.dsts[i] != `ZERO_REG) begin
                d_out.ts_old[i]             = entries_n[d_in.dsts[i]].t;
                entries_n[d_in.dsts[i]].t   = d_in.ts[i];
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int r = 1; r < `NUM_ARCH_REG; ++r) begin
                entries[r] <= '{
                    t : r    // ✅ Map PRx = Rx (Arch Reg x → PRx)
                };
            end
            entries[`ZERO_REG]  <= '{
                t   : '0
            }; // Ensure ZERO_REG always maps to PR0
        end else if (flush) begin
            for (int unsigned r = 0; r < `NUM_ARCH_REG; ++r) begin
                entries[r] <= '{
                    t   : am_in.state[r].t
                };
            end
        end else begin
            entries <= entries_n;
            `ifndef SYNTH
            if (entries[`ZERO_REG].t != '0) begin
                $error("ERROR: entries[0] was modified! Got: {t:%0d}", 
                    entries[`ZERO_REG].t
                );
            end
            `endif
        end
    end

    `ifdef DEBUG
    // debugging
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | >> MT >>", $time);
            $display("dis_in:   {en_cnt: %d, [(%0d->%0d, %d, %d), (%0d->%0d, %d, %d)]}",
                d_in.en_cnt,
                d_in.dsts[0],
                d_in.ts[0],
                d_in.src1s[0],
                d_in.src2s[0],
                d_in.dsts[1],
                d_in.ts[1],
                d_in.src1s[1],
                d_in.src2s[1]
            );
            $display("dis_out:  {en_cnt: %d, [(told: %0d, t1: %0d, t2: %0d), (told: %0d, t1: %0d, t2: %0d)]}",
                d_in.en_cnt,
                d_out.ts_old[0],
                d_out.t1s[0],
                d_out.t2s[0],

                d_out.ts_old[1],
                d_out.t1s[1],
                d_out.t2s[1]
            );
            $display("  %3d | << MT <<", $time);
        end
    end
    `endif

endmodule
