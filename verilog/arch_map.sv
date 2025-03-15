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
    input clock, reset,
    // retire
    input retire2archmap r_in

    // complete ??
    // issue ??
    // dispatch ??
);
    localparam NUM_ARCH_REG = 32;
    struct packed {
        PHYS_REG_IDX    t;
    } [NUM_ARCH_REG-1:0] entries, entries_n;

    always_comb begin
        entries_n = entries;
        // handle completes
        for (int i = 0; i < r_in.en_cnt; ++i) begin
            /* Checking for ZERO_REG is presumably not necessary since it cannot
            be allocated as a dest reg... No wait it can? But it will just write
            the preg#0 tag anyways, right?
            */
            if (r_in.dsts[i] == ZERO_REG)
                continue;
            entries_n[r_in.dsts[i]] = r_in.ts[i];
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            entries[`ZERO_REG] <= '{
                t : '0
            };
            for (int r = 1; r < NUM_ARCH_REG; ++r) begin
                entries[r].t <= r;  // ✅ Map PRx = Rx (Arch Reg x → PRx)
            end
        end else begin
            entries <= entries_n;
        end
    end
endmodule
