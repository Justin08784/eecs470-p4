`include "sys_defs.svh"


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