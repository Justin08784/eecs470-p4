/* 
================================================
Architectural Map
================================================
*/
// Comments:
// - similar to map table, submodule to ROB?
module arch_map #(parameter 
    N=`N
) (
    input clock, reset, flush,

    // flush
    output arch_map2map_table mt_out,

    // retire
    input  retire_final r_in

    // complete ??
    // issue ??
    // dispatch ??
);
    struct packed {
        PHYS_REG_IDX    t;
    } [`NUM_ARCH_REG-1:0] entries, entries_n;

    assign mt_out = entries;

    always_comb begin
        entries_n = entries;
        // handle completes
        for (int i = 0; i < r_in.r_en_cnt; ++i) begin
            /* Checking for ZERO_REG is presumably not necessary since it cannot
            be allocated as a dest reg... No wait it can? But it will just write
            the preg#0 tag anyways, right?
            */
            if (r_in.dst[i] == `ZERO_REG)
                continue;
            entries_n[r_in.dst[i]] = '{t : r_in.tag[i]};
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            entries[`ZERO_REG] <= '{t : '0};
            for (int r = 1; r < `NUM_ARCH_REG; ++r) begin
                entries[r] <= '{t : r}; // ✅ Map PRx = Rx (Arch Reg x → PRx)
            end
        end else if (!flush) begin
            entries <= entries_n;
        end
    end
endmodule
