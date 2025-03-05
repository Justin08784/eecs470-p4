`include "sys_defs.svh"

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
    } d_out
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
                entries_n[r].cpl |= (entries_n[r].t == c_in.c_ts[i]);
            end
        end

        // handle renames
        for (int i = 0; i < d_in.en_cnt; ++i) begin
            /*
            Idea: how about we always map ZERO_REG -> preg #0, cpl=1,
            and it cannot be edited?
            */
            d_out.t1s[i]    = entries_n[d_in.src1s[i]].t;
            d_out.t2s[i]    = entries_n[d_in.src2s[i]].t;
            d_out.cpl1s[i]  = entries_n[d_in.src1s[i]].cpl;
            d_out.cpl2s[i]  = entries_n[d_in.src2s[i]].cpl;

            if (d_in.dsts[i] != `ZERO_REG) begin
                entries_n[d_in.dsts[i]].t   = d_in.ts[i];
                entries_n[d_in.dsts[i]].cpl = 0;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            entries <= '0;
            entries[`ZERO_REG] <= '{
                t : '0,
                cpl : 1
            };
        end else begin
            entries <= entries_n;
        end
    end
endmodule


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


// module map_table(
//     input clock,
//     input reset,
// 
//     input PHYS_REG_IDX changed_tags [31:0],
//     input tag_vld [31:0],
// 
//     output PHYS_REG_IDX map_table [31:0]
// );
// 
// logic PHYS_REG_IDX next_map [31:0];
// 
// 
// always_comb begin
//     for (int i = 0; i < 32; i++) begin
//         next_map[i] = tag_vld[i] ? changed_tags[i] : map_table[i];
//     end
// end
// 
// 
// always_ff @(posedge clock) begin
//     if (reset) begin
//         map_table <= default_map_table();
//     end
//     else begin
//         map_table <= next_map;
//     end    
// end
// 
// endmodule
// 
// 
// 
// module arch_map(
//     input clock,
//     input reset,
// 
//     input PHYS_REG_IDX changed_tags [31:0],
//     input tag_vld [31:0],
// 
//     output PHYS_REG_IDX arch_table [31:0]
// );
// 
// logic PHYS_REG_IDX next_arch [31:0];
// 
// 
// always_comb begin
//     for (int i = 0; i < 32; i++) begin
//         next_arch[i] = tag_vld[i] ? changed_tags[i] : arch_table[i];
//     end
// end
// 
// 
// always_ff @(posedge clock) begin
//     if (reset) begin
//         arch_table <= default_map_table();
//     end
//     else begin
//         arch_table <= next_arch;
//     end    
// end
// 
// endmodule
// 
// 
// 
// module free_list(
//     input clock,
//     input reset,
// 
//     input PHYS_REG_IDX changed_tags [`PHYS_REG_SZ_R10K-1:0],
// 
//     output PHYS_REG_IDX free_list [`PHYS_REG_SZ_R10K-1:0]
// );
// 
// logic PHYS_REG_IDX next_free [`PHYS_REG_SZ_R10K-1:0];
// 
// //Updates the free list indices based on whether it is marked to become free or
// //if it is already free and still marked to be free next cycle
// always_comb begin
//     for (int i = 0; i < `PHYS_REG_SZ_R10K; i++) begin
//         next_free[i] = changed_tags[i] || (free_list[i] && changed_tags[i]);
//     end
// end
// 
// 
// always_ff @(posedge clock) begin
//     if (reset) begin
//         free_list <= '1;
//     end
//     else begin
//         free_list <= next_free;
//     end
// end
// 
// 
// endmodule
// 
// 
// task default_map_table;
// 
//     output default_table;
// 
//     begin
// 
//     end
// endtask