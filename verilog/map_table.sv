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
    output MAP_TABLE_ENTRY [`NUM_ARCH_REG-1:0] entries_dbg,
    `endif

    // flush
    input arch_map2map_table am_in,

    // retire ??

    // complete
    input execute2complete c_in,

    // issue ??

    // dispatch
    input dispatch2map_table d_in,
    output map_table2dispatch d_out
);
    MAP_TABLE_ENTRY [`NUM_ARCH_REG-1:0] entries;
    /*
    NOTE: We have N intermediate stages, not N-1!!
    0: after completes
    1: after dispatch 0
    2: after dispatch 1
    */
    MAP_TABLE_ENTRY [`N:0][`NUM_ARCH_REG-1:0] entries_n;
    `ifdef DEBUG
    assign entries_dbg = entries;
    `endif

    always_comb begin
        entries_n[0] = entries;
        d_out = '0;
        // handle completes
        for (int i = 0; i < N; ++i) begin
            /* Checking for preg#0 is presumably not necessary since it cannot
            be allocated as a dest reg. */
            // if (!c_in.c_en[i] || c_in.c_ts[i] == `0)
            //     continue;
            if (!c_in.c_en[i])
                continue;
            for (int r = 0; r < `NUM_ARCH_REG; ++r) begin
                entries_n[0][r].cpl |= (entries[r].t == c_in.c_ts[i]);
            end
        end

        // handle renames
        for (int i = 0; i < d_in.en_cnt; ++i) begin
            entries_n[i + 1] = entries_n[i];
            /*
            Idea: how about we always map ZERO_REG -> preg #0, cpl=1,
            and it cannot be edited?
            */
            d_out.t1s[i]    = entries_n[i][d_in.src1s[i]].t;
            d_out.t2s[i]    = entries_n[i][d_in.src2s[i]].t;
            d_out.cpl1s[i]  = !d_in.is_rs1s[i] || entries_n[i][d_in.src1s[i]].cpl;
            d_out.cpl2s[i]  = !d_in.is_rs2s[i] || entries_n[i][d_in.src2s[i]].cpl;

            if (d_in.dsts[i] != `ZERO_REG) begin
                d_out.ts_old[i] = entries_n[i][d_in.dsts[i]].t;
                entries_n[i + 1][d_in.dsts[i]].t   = d_in.ts[i];
                entries_n[i + 1][d_in.dsts[i]].cpl = 0;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int r = 1; r < `NUM_ARCH_REG; ++r) begin
                entries[r] <= '{
                    t   : r,    // ✅ Map PRx = Rx (Arch Reg x → PRx)
                    cpl : 1     // Mark all as initially completed
                };
            end
            entries[`ZERO_REG]  <= '{
                t   : '0,
                cpl : 1
            }; // Ensure ZERO_REG always maps to PR0
        end else if (flush) begin
            for (int unsigned r = 0; r < `NUM_ARCH_REG; ++r) begin
                entries[r] <= '{
                    t   : am_in.state[r].t,
                    cpl : 1
                };
            end
        end else begin
            entries <= entries_n[d_in.en_cnt];
            `ifndef SYNTH
            if (entries[`ZERO_REG].t != '0 || !entries[`ZERO_REG].cpl) begin
                $error("ERROR: entries[0] was modified! Got: {t:%0d, cpl:%b}", 
                    entries[`ZERO_REG].t,
                    entries[`ZERO_REG].cpl
                );
            end
            `endif
        end
    end

    `ifndef SYNTH
    // debugging
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | MT >>", $time);
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
            $display("dis_out:  {en_cnt: %d, [(told: %0d, t1: %0d<%b>, t2: %0d<%b>), (told: %0d, t1: %0d<%b>, t2: %0d<%b>)]}",
                d_in.en_cnt,
                d_out.ts_old[0],
                d_out.t1s[0],
                d_out.cpl1s[0],
                d_out.t2s[0],
                d_out.cpl2s[0],

                d_out.ts_old[1],
                d_out.t1s[1],
                d_out.cpl1s[1],
                d_out.t2s[1],
                d_out.cpl2s[1]
            );
            for (int i = 0; i <= `N; ++i) begin
                for (int j = 0; j < `NUM_ARCH_REG; ++j) begin
                    $display("chk[%0d] (r->t: %0d->%0d, cpl: %b)", i, j, entries_n[i][j].t, entries_n[i][j].cpl);
                end
                $display("");
            end
            $display("  %3d | MT <<", $time);
        end
    end
    `endif

endmodule
