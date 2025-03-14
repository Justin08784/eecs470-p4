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
    input struct packed {
        logic         [$clog2(N):0] en_cnt;
            // - Number of enabled retire lines?
            // - Question: Does this need to be a count, or can we make it an enable
            // bus? I fear that there can be serial dependencies and ordering issues
            // e.g. if multiple insns retire to the same dest arch register.
        REG_IDX       [N-1:0] dsts;
        PHYS_REG_IDX  [N-1:0] ts;
            // From: retire (ROB)
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } r_in

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
            // if (r_in.dsts[i] == ZERO_REG)
            //     continue;
            entries_n[r_in.dsts[i]] = r_in.ts[i];
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            entries <= '0;
            entries[`ZERO_REG] <= '{
                t : '0
            };
        end else begin
            entries <= entries_n;
        end
    end
endmodule
