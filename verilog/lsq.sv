`include "sys_defs.svh"


module lsq #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
    LSQ_SZ_DBL=`LSQ_SZ_DBL,
    NUM_FU_STORE=`NUM_FU_STORE,
    NUM_FU_LOAD=`NUM_FU_LOAD
) (
    `ifdef DEBUG
    output  SQ_ENTRY   [LSQ_SZ-1:0]    state_dbg,
    `endif 
    input clock,
    input reset,
    input flush,

    input dispatch2lsq dis_2_lsq,
    input execute2lsq exec_2_lsq,
    input rob2lsq rob_2_lsq,

    output lsq2dispatch lsq_2_dis,
    output lsq2execute lsq_2_exec,
    output lsq2rs lsq_2_rs,
    output lsq2rob lsq_2_rob,
    output stRET2mem ret_2_mem,
    output MEM_TAG mem2proc_transaction_tag
);

    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_ST_PORTS = NUM_FU_STORE; // ex-2-sq ports
    localparam NUM_LD_PORTS = NUM_FU_LOAD;
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(LSQ_SZ)-1:0]  head;
    logic [$clog2(LSQ_SZ)-1:0]  tail;
    logic [$clog2(LSQ_SZ_DBL)-1:0]  tail_dbl;

    SQ_ENTRY [LSQ_SZ-1:0]       state;
    logic [$clog2(LSQ_SZ):0]    used, free;

    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;

    lsq2stRET lsq_2_ret;
    stRET2lsq ret_2_lsq;

    assign state_dbg            = state;
    assign free                 = LSQ_SZ - used;
    assign free_scnt            = `MIN(free, NUM_DPORTS);
    assign used_scnt            = `MIN(used, NUM_RPORTS);


    post_ret_buffer buf_dut(
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .lsq_2_ret(lsq_2_ret),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .ret_2_lsq(ret_2_lsq),
        .ret_2_mem(ret_2_mem)
    );


    LSQ_IDX head_plus_one;
    logic [NUM_FU_LOAD-1:0] [$clog2(LSQ_SZ):0] forward_found;
    LSQ_IDX [NUM_FU_LOAD-1:0] [LSQ_SZ-1:0] forward_idx;
    struct packed {
        ADDR        [NUM_FU_LOAD-1:0]   start;
        ADDR        [NUM_FU_LOAD-1:0]   stop;
        MEM_SIZE    [NUM_FU_LOAD-1:0]   start_sz_req;
    } forward_range;
    logic [N-1:0] [$clog2(LSQ_SZ_DBL)-1:0] next_ids;
    always_comb begin

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            next_ids[i] = (tail_dbl + i) % LSQ_SZ_DBL;

        // handle dispatch (outs)
        lsq_2_dis <= '{
            sq_rdy_scnt : `MIN(free, NUM_DPORTS),
            sq_tail     : tail_dbl
        };

        //handle LSQ CDB to RS
        lsq_2_rs <= '{
            en : exec_2_lsq.ex_en,
            sq_idx_cdb     : exec_2_lsq.sq_idx
        };

        //handle lsq to ROB for retirement
        head_plus_one = (head + 1) % LSQ_SZ;
        if (state[head].d_vld && state[head_plus_one].d_vld)    lsq_2_rob.ret_rdy = 2;
        else if (state[head].d_vld)                             lsq_2_rob.ret_rdy = 1;
        else                                                    lsq_2_rob.ret_rdy = 0;
        lsq_2_rob.ret_rdy = `MIN(lsq_2_rob.ret_rdy,ret_2_lsq.free_out);
        lsq_2_rob.sq_ret_complete = (ret_2_lsq.empty && (used == 0)) ? '1 : '0;

        //handle retirement write to mem
        lsq_2_ret.ret_cnt   = rob_2_lsq.r_en;
        lsq_2_ret.ret_st[0] = state[head];
        lsq_2_ret.ret_st[1] = state[head_plus_one];

        //handle data forwarding
        lsq_2_ret.forward_req_en    = exec_2_lsq.forward_req_en;
        lsq_2_ret.sq_idx            = exec_2_lsq.sq_idx;
        lsq_2_ret.forward_addr      = exec_2_lsq.forward_addr;
        lsq_2_ret.ld_mem_size       = exec_2_lsq.ld_mem_size;

        forward_found = '0;
        forward_idx = '0;
        lsq_2_exec = '0;
        //calculate ADDR ranges to search for forwarding
        forward_range = '0;
        for (int unsigned i = 0; i < NUM_FU_LOAD; i++) begin
            forward_range.start[i] = exec_2_lsq.forward_addr[i] - (exec_2_lsq.forward_addr[i] % 8);
            forward_range.stop[i] = forward_range.start[i] + 16;
        end

        //search for matches to forward
        for (int unsigned i = 0; i < NUM_FU_LOAD; i++) begin
            if (!exec_2_lsq.forward_req_en[i]) continue;

            //find any addr's in the SQ that are within range
            for (int unsigned j = 0, int idx = 0; j < LSQ_SZ; j++) begin
                idx = (head+j) % LSQ_SZ;

                if (state[idx].d_vld && (forward_range.start[i] <= state[idx].addr) && (state[idx].addr < forward_range.stop[i])) begin
                    forward_idx[i][forward_found] = idx;
                    forward_found += 1;
                end

                if (state[idx].sq_idx == exec_2_lsq.sq_idx[i]) break;
            end
        end

        // for (int unsigned i = 0; i < NUM_FU_LOAD; i++) begin
        //     if (!exec_2_lsq.forward_req_en[i]) continue;

        //     for (int unsigned j = 0, int idx = 0; j < LSQ_SZ; j++) begin
        //         idx = (head+j) % LSQ_SZ;

        //         if (state[idx].d_vld && (state[idx].addr == exec_2_lsq.forward_addr[i])) begin
        //             forward_idx[i] = idx; //don't want to break when found bc there could be a more recent store between here and the sq_idx
        //             forward_found[i] = '1;
        //             // $display("forward_found: %0d", forward_idx[i]);
        //         end
        //         // $display("Current[%0d]: %0d, %0d, %0d", i, state[idx].d_vld, state[idx].addr, exec_2_lsq.forward_addr[i]);
        //         if (state[idx].sq_idx == exec_2_lsq.sq_idx[i]) break;
        //     end

        //     if (forward_found[i]) begin
        //         // $display("here6: %0d", forward_idx[i]);
        //         lsq_2_exec.forward_en[i] = state[forward_idx[i]].d_vld;
        //         lsq_2_exec.forward_addr[i] = state[forward_idx[i]].addr;
        //         lsq_2_exec.forward_data[i] = state[forward_idx[i]].data;
        //         lsq_2_exec.forward_mem_size[i] = state[forward_idx[i]].mem_size;
        //     end
        //     else if (ret_2_lsq.forward_en[i]) begin
        //         // $display("here5: %0d",i);
        //         lsq_2_exec.forward_en[i] |= '1;//ret_2_lsq.forward_en[i];
        //         lsq_2_exec.forward_addr[i] |= ret_2_lsq.forward_addr[i];
        //         lsq_2_exec.forward_data[i] |= ret_2_lsq.forward_data[i];
        //         lsq_2_exec.forward_mem_size[i] = ret_2_lsq.forward_mem_size[i];
        //     end

        // end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            tail_dbl <= 0;
            state   <= '0;
        end else begin
            used    <= used + dis_2_lsq.lsq_d_en_cnt - rob_2_lsq.r_en;
            head    <= (head + rob_2_lsq.r_en) % LSQ_SZ;
            tail    <= (tail + dis_2_lsq.lsq_d_en_cnt) % LSQ_SZ;
            tail_dbl <= (tail_dbl + dis_2_lsq.lsq_d_en_cnt) % LSQ_SZ_DBL;
            
            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
                cur_idx = exec_2_lsq.sq_idx[i];

                if (exec_2_lsq.ex_en[i]) begin
                    state[cur_idx].addr <= exec_2_lsq.addr[i];
                    state[cur_idx].data <= exec_2_lsq.data[i];
                    state[cur_idx].mem_size <= exec_2_lsq.st_mem_size[i];
                    state[cur_idx].d_vld <= '1;
                end

            end

            // handle dispatch (ins)
            // $display("d_en_cnt: %d", d_in.d_en_cnt);
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= dis_2_lsq.lsq_d_en_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    sq_idx     : next_ids[i],
                    rob_idx : dis_2_lsq.rob_idx[i],
                    addr     : '0,
                    data   : '0,
                    d_vld     : '0,
                    mem_size : '0
                };
            end

            `ifndef SYNTH
            $display("  %3d | >> LSQ", $time);
            for (int i = 0; i < LSQ_SZ; i++) begin
                $display("Entry [%0d]: id=%0d, rob_idx=%0d, addr=%0d, data=%0d, d_valid=%b",
                i,
                state[i].sq_idx,
                state[i].rob_idx,
                state[i].addr,
                state[i].data,
                state[i].d_vld
                );
            end
            $display("  %3d | << LSQ", $time);
            `endif
        end
    end

endmodule


module post_ret_buffer #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
    LSQ_SZ_DBL=`LSQ_SZ_DBL,
    NUM_FU_STORE=`NUM_FU_STORE,
    NUM_FU_LOAD=`NUM_FU_LOAD
) (
    input clock,
    input reset,
    input flush,

    input lsq2stRET lsq_2_ret,
    input MEM_TAG mem2proc_transaction_tag,

    output stRET2lsq ret_2_lsq,
    output stRET2mem ret_2_mem
);

    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_ST_PORTS = NUM_FU_STORE; // ex-2-sq ports
    localparam NUM_LD_PORTS = NUM_FU_LOAD;
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(LSQ_SZ)-1:0]  head;
    logic [$clog2(LSQ_SZ)-1:0]  tail;

    SQ_ENTRY [LSQ_SZ-1:0]       state;
    logic [$clog2(LSQ_SZ):0]    used, free;

    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;

    assign state_dbg            = state;
    assign free                 = LSQ_SZ - used;
    assign free_scnt            = `MIN(free, NUM_DPORTS);
    assign used_scnt            = `MIN(used, NUM_RPORTS);

    logic [$clog2(N):0] ret_success;

    logic [NUM_FU_LOAD-1:0] forward_found;
    LSQ_IDX [NUM_FU_LOAD-1:0] forward_idx;
    always_comb begin
        ret_2_lsq = '0;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;

        // handle ret_2_lsq
        ret_2_lsq.free_out = `MIN(free, NUM_DPORTS);
        ret_2_lsq.empty = (used == 0) ? '1 : '0;

        //handle retirement write to mem
        ret_2_mem = '0;
        if (head != tail) begin
            ret_2_mem.Dmem_command = MEM_STORE;
            ret_2_mem.Dmem_addr = state[head].addr;
            ret_2_mem.Dmem_store_data = state[head].data;
            ret_2_mem.Dmem_size = state[head].mem_size;
        end
        ret_success = (mem2proc_transaction_tag != 0) ? 1 : 0;

        //data forwarding
        forward_found = '0;
        forward_idx = '0;
        // for (int unsigned i = 0; i < NUM_FU_STORE; i++) begin
        //     for (int unsigned j = 0, int idx = 0; j < LSQ_SZ; j++) begin
        //         idx = (head+j) % LSQ_SZ;

        //         if (state[idx].d_vld && (state[idx].addr == lsq_2_ret.forward_addr[i])) begin
        //             forward_idx[i] = idx; //don't want to break when found bc there could be a more recent store between here and the sq_idx
        //             forward_found[i] = '1;
        //             // $display("forward_found: %0d", forward_idx[i]);
        //         end
        //         // $display("Current[%0d]: %0d, %0d, %0d", i, state[idx].d_vld, state[idx].addr, lsq_2_ret.forward_addr[i]);
        //         if (state[idx].sq_idx == lsq_2_ret.sq_idx[i]) break;
        //     end

        //     if (forward_found[i]) begin
        //         // $display("here6: %0d", forward_idx[i]);
        //         ret_2_lsq.forward_en[i] = state[forward_idx[i]].d_vld;
        //         ret_2_lsq.forward_addr[i] = state[forward_idx[i]].addr;
        //         ret_2_lsq.forward_data[i] = state[forward_idx[i]].data;
        //         ret_2_lsq.forward_mem_size[i] = state[forward_idx[i]].mem_size;
        //     end
        // end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            state   <= '0;
        end else begin
            used    <= used + lsq_2_ret.ret_cnt - ret_success;
            head    <= (head + ret_success) % LSQ_SZ;
            tail    <= (tail + lsq_2_ret.ret_cnt) % LSQ_SZ;

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= lsq_2_ret.ret_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= lsq_2_ret.ret_st[i];
            end

            `ifndef SYNTH
            $display("  %3d | >> RET buffer", $time);
            for (int i = 0; i < LSQ_SZ; i++) begin
                $display("Entry [%0d]: id=%0d, rob_idx=%0d, addr=%0d, data=%0d, d_valid=%b",
                i,
                state[i].sq_idx,
                state[i].rob_idx,
                state[i].addr,
                state[i].data,
                state[i].d_vld
                );
            end
            $display("  %3d | << RET buffer", $time);
            `endif
        end
    end

endmodule