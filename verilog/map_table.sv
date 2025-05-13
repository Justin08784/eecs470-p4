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
`ifdef DEBUG
    input struct packed {
        logic [`PHYS_REG_SZ_R10K-1:0][$bits(DATA)-1:0] file;
    } dbg_prf,
`endif
    input  clock,
    input  reset,
    input  flush,

    // flush
    input  arch_map2map_table am_in,

    // dispatch
    input  dispatch2map_table d_in,
    output map_table2dispatch d_out
);
    PHYS_REG_IDX [`NUM_ARCH_REG-1:0] entries, entries_n;

    always_comb begin
        entries_n = entries;
        d_out = '0;

        // handle renames
        for (int i = 0; i < d_in.en_cnt; ++i) begin
            /*
            Idea: how about we always map ZERO_REG -> preg #0, cpl=1,
            and it cannot be edited?
            */
            d_out.t1s[i] = entries_n[d_in.src1s[i]];
            d_out.t2s[i] = entries_n[d_in.src2s[i]];
            if (d_in.dsts[i] != `ZERO_REG) begin
                d_out.ts_old[i]         = entries_n[d_in.dsts[i]];
                entries_n[d_in.dsts[i]] = d_in.ts[i];
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            entries[`ZERO_REG] <= '0;
            for (int r = 1; r < `NUM_ARCH_REG; ++r)
                entries[r] <= r;

        end else if (flush) begin
            for (int r = 1; r < `NUM_ARCH_REG; ++r)
                entries[r] <= am_in.entries[r];

        end else begin
            entries <= entries_n;
`ifndef SYNTH
            if (entries[`ZERO_REG] != '0)
                $error("ERROR: entries[0] was modified! Got: {t:%0d}", entries[`ZERO_REG]);
`endif
        end

    end

`ifdef DEBUG
    task print_map_table();
        $display(">> MT >>", $time);
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
        for (int r = 0; r < `NUM_ARCH_REG; ++r) begin
            logic duplicate;
            duplicate = 0;
            for (int rp = 0; rp < `NUM_ARCH_REG; ++rp) begin
                if (rp != r && entries[rp] == entries[r]) begin
                    duplicate = 1;
                    break;
                end
            end
            $display("mt[%2d]: t=%3d, v=%x :::: am[%2d]: t=%3d, v=%x  (has_dup: %b)",
                r,
                entries[r],
                dbg_prf.file[entries[r]],
                r, 
                am_in.entries[r],
                dbg_prf.file[am_in.entries[r]],
                duplicate
            );
        end
        $display("<< MT <<", $time);
    endtask
`endif

endmodule
