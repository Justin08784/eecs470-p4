// `include "sys_defs.svh"

// module post_ret_buffer #(parameter 
//     N=`N,
//     LSQ_SZ=`LSQ_SZ,
//     LSQ_SZ_DBL=`LSQ_SZ_DBL,
//     NUM_FU_STORE=`NUM_FU_STORE,
//     NUM_FU_LOAD=`NUM_FU_LOAD
// ) (
//     input clock,
//     input reset,
//     input flush,

//     input lsq2stRET lsq_2_ret,
//     input MEM_TAG mem2proc_transaction_tag,

//     output stRET2lsq ret_2_lsq,
//     output stRET2mem ret_2_mem
// );

//     localparam NUM_DPORTS = N; // dispatch ports (in-order)
//     localparam NUM_RPORTS = N; // retire ports (in-order)
//     localparam NUM_ST_PORTS = NUM_FU_STORE; // ex-2-sq ports
//     localparam NUM_LD_PORTS = NUM_FU_LOAD;
//     logic [$clog2(NUM_DPORTS):0]    free_scnt;
//     logic [$clog2(NUM_RPORTS):0]    used_scnt;

//     logic [$clog2(LSQ_SZ)-1:0]  head;
//     logic [$clog2(LSQ_SZ)-1:0]  tail;

//     SQ_ENTRY [LSQ_SZ-1:0]       state;
//     logic [$clog2(LSQ_SZ):0]    used, free;

//     logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
//     logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;

//     assign state_dbg            = state;
//     assign free                 = LSQ_SZ - used;
//     assign free_scnt            = `MIN(free, NUM_DPORTS);
//     assign used_scnt            = `MIN(used, NUM_RPORTS);

//     logic [$clog2(N):0] ret_success;

//     logic [NUM_FU_LOAD-1:0] forward_found;
//     LSQ_IDX [NUM_FU_LOAD-1:0] forward_idx;
//     always_comb begin
//         ret_2_lsq = '0;

//         for (int unsigned i = 0; i < NUM_RPORTS; ++i)
//             r_idxs[i] = (head + i) % LSQ_SZ;
//         for (int unsigned i = 0; i < NUM_DPORTS; ++i)
//             d_idxs[i] = (tail + i) % LSQ_SZ;

//         // handle ret_2_lsq
//         ret_2_lsq.free_out = `MIN(free, NUM_DPORTS);
//         ret_2_lsq.empty = (used == 0) ? '1 : '0;

//         //handle retirement write to mem
//         ret_2_mem = '0;
//         if (head != tail) begin
//             ret_2_mem.Dmem_command = MEM_STORE;
//             ret_2_mem.Dmem_addr = state[head].addr;
//             ret_2_mem.Dmem_store_data = state[head].data;
//             ret_2_mem.Dmem_size = state[head].mem_size;
//         end
//         ret_success = (mem2proc_transaction_tag != 0) ? 1 : 0;

//         //data forwarding
//         forward_found = '0;
//         forward_idx = '0;
//         for (int unsigned i = 0; i < NUM_FU_STORE; i++) begin
//             for (int unsigned j = 0, int idx = 0; j < LSQ_SZ; j++) begin
//                 idx = (head+j) % LSQ_SZ;

//                 if (state[idx].d_vld && (state[idx].addr == lsq_2_ret.forward_addr[i])) begin
//                     forward_idx[i] = idx; //don't want to break when found bc there could be a more recent store between here and the sq_idx
//                     forward_found[i] = '1;
//                     // $display("forward_found: %0d", forward_idx[i]);
//                 end
//                 // $display("Current[%0d]: %0d, %0d, %0d", i, state[idx].d_vld, state[idx].addr, lsq_2_ret.forward_addr[i]);
//                 if (state[idx].sq_idx == lsq_2_ret.sq_idx[i]) break;
//             end

//             if (forward_found[i]) begin
//                 // $display("here6: %0d", forward_idx[i]);
//                 ret_2_lsq.forward_en[i] = state[forward_idx[i]].d_vld;
//                 ret_2_lsq.forward_addr[i] = state[forward_idx[i]].addr;
//                 ret_2_lsq.forward_data[i] = state[forward_idx[i]].data;
//                 ret_2_lsq.forward_mem_size[i] = state[forward_idx[i]].mem_size;
//             end
//         end
//     end


//     always_ff @(posedge clock) begin
//         if (reset || flush) begin
//             used    <= 0;
//             head    <= 0;
//             tail    <= 0;
//             state   <= '0;
//         end else begin
//             used    <= used + lsq_2_ret.ret_cnt - ret_success;
//             head    <= (head + ret_success) % LSQ_SZ;
//             tail    <= (tail + lsq_2_ret.ret_cnt) % LSQ_SZ;

//             // handle dispatch (ins)
//             for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
//                 if (i >= lsq_2_ret.ret_cnt)
//                     continue;
//                 cur_idx = d_idxs[i];
//                 state[cur_idx] <= lsq_2_ret.ret_st[i];
//             end

//             `ifndef SYNTH
//             $display("  %3d | >> RET buffer", $time);
//             for (int i = 0; i < LSQ_SZ; i++) begin
//                 $display("Entry [%0d]: id=%0d, rob_idx=%0d, addr=%0d, data=%0d, d_valid=%b",
//                 i,
//                 state[i].sq_idx,
//                 state[i].rob_idx,
//                 state[i].addr,
//                 state[i].data,
//                 state[i].d_vld
//                 );
//             end
//             $display("  %3d | << RET buffer", $time);
//             `endif
//         end
//     end

// endmodule