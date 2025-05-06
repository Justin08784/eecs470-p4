/* 
================================================
Architectural Map
================================================
*/
module arch_map #(parameter 
    N=`N
) (
    input clock, reset, flush,

    // flush
    output arch_map2map_table mt_out,

    // retire
    input  retire_final r_in
);
    PHYS_REG_IDX [`NUM_ARCH_REG-1:0] entries, entries_n;
    assign mt_out.entries = entries;

    always_comb begin
        entries_n = entries;
        // handle retires
        for (int i = 0; i < r_in.r_en_cnt; ++i) begin
            if (r_in.dst[i] == `ZERO_REG) // e.g. store, brch insns have 0 dest preg
                continue;
            entries_n[r_in.dst[i]] = r_in.tag[i];
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            entries[`ZERO_REG] <= '0;
            for (int r = 1; r < `NUM_ARCH_REG; ++r)
                entries[r] <= r;
        end else if (!flush) begin
            entries <= entries_n;
        end
    end
endmodule
