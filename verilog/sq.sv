`include "sys_defs.svh"


module sq #(parameter 
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
    input MEM_TAG mem2proc_transaction_tag,

    output lsq2dispatch lsq_2_dis,
    output lsq2execute lsq_2_exec,
    output lsq2rs lsq_2_rs,
    output lsq2rob lsq_2_rob,
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
    logic [$clog2(LSQ_SZ_DBL)-1:0]  tail_dbl;

    SQ_ENTRY [LSQ_SZ-1:0]       state;
    logic [$clog2(LSQ_SZ):0]    used, free;

    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;

    lsq2stRET lsq_2_ret;
    stRET2lsq ret_2_lsq;
    forwardRET2lsq forward_ret_2_lsq;

    `ifdef DEBUG
    assign state_dbg            = state;
    `endif 
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
        .forward_ret_2_lsq(forward_ret_2_lsq),
        .ret_2_mem(ret_2_mem)
    );


    LSQ_IDX head_plus_one;
    logic [NUM_FU_LOAD-1:0] forward_found;
    LSQ_IDX [NUM_FU_LOAD-1:0] forward_idx;
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
            en : exec_2_lsq.st_ex_en,
            sq_idx_cdb     : exec_2_lsq.st_sq_idx
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

        

    end

    logic [4:0] adj_k;
    logic [1:0] byte_num;
    always_comb begin
        lsq_2_exec = '0;

        //handle data forwarding
        lsq_2_ret.forward_req_en    = exec_2_lsq.forward_req_en;
        lsq_2_ret.forward_sq_idx            = exec_2_lsq.forward_sq_idx;
        lsq_2_ret.forward_addr      = exec_2_lsq.forward_addr;
        lsq_2_ret.forward_mem_size       = exec_2_lsq.forward_mem_size;

        forward_found = '0;
        forward_idx = '0;
        //calculate ADDR ranges to search for forwarding
        forward_range = '0;
        for (int unsigned i = 0; i < NUM_FU_LOAD; i++) begin
            forward_range.start[i] = exec_2_lsq.forward_addr[i] - (exec_2_lsq.forward_addr[i] % 4);
            forward_range.stop[i] = forward_range.start[i] + 4;
        end

        for (int unsigned i = 0, ADDR start = 0; i < NUM_FU_LOAD; i++) begin
            if (!exec_2_lsq.forward_req_en[i]) continue;

            start = exec_2_lsq.forward_addr[i] - (exec_2_lsq.forward_addr[i] % 4);
            for (int unsigned j = 0, int unsigned idx = 0, DATA shifted_data = 0, int unsigned offset = 0, logic [1:0] modulo4 = 0; j < used; ++j) begin
                idx = (head+j) % LSQ_SZ;modulo4 = state[idx].addr % 4;
                offset = (modulo4 == 0) ? 0 : (modulo4 == 1) ? 8 : (modulo4 == 2) ? 16 : 24;
                // offset = (8*(2**(state[idx].addr % 4))-8);
                shifted_data = state[idx].data << offset;
                if (state[idx].d_vld && (state[idx].bytewise_addr[0] == start)) begin
                    // $display("Mask: %4b", state[idx].bytewise_addr_mask);
                    // $display("Addr: %0d, Data: %0d, Shifted: %0d, Offset: %0d", state[idx].addr, state[idx].data, shifted_data, offset);
                    lsq_2_exec.forward_data[i][7:0] = state[idx].bytewise_addr_mask[0] ? shifted_data[7:0] : lsq_2_exec.forward_data[i][7:0];
                    lsq_2_exec.forward_data[i][15:8] = state[idx].bytewise_addr_mask[1] ? shifted_data[15:8] : lsq_2_exec.forward_data[i][15:8];
                    lsq_2_exec.forward_data[i][23:16] = state[idx].bytewise_addr_mask[2] ? shifted_data[23:16] : lsq_2_exec.forward_data[i][23:16];
                    lsq_2_exec.forward_data[i][31:24] = state[idx].bytewise_addr_mask[3] ? shifted_data[31:24] : lsq_2_exec.forward_data[i][31:24];
                    lsq_2_exec.forward_byte_en[i] |= state[idx].bytewise_addr_mask;
                end

                if (state[idx].sq_idx == exec_2_lsq.forward_sq_idx[i]) break;
            end

            lsq_2_exec.forward_en[i] = (lsq_2_exec.forward_byte_en[i] != 0) ? '1 : '0;

            if ((exec_2_lsq.forward_addr[i] % 4) == 1) begin
                lsq_2_exec.forward_data[i] = lsq_2_exec.forward_data[i] >> 8;
                lsq_2_exec.forward_byte_en[i] = lsq_2_exec.forward_byte_en[i] >> 8;
            end
            else if ((exec_2_lsq.forward_addr[i] % 4) == 2) begin
                lsq_2_exec.forward_data[i] = lsq_2_exec.forward_data[i] >> 16;
                lsq_2_exec.forward_byte_en[i] = lsq_2_exec.forward_byte_en[i] >> 16;
            end
            else if ((exec_2_lsq.forward_addr[i] % 4) == 3) begin
                lsq_2_exec.forward_data[i] = lsq_2_exec.forward_data[i] >> 24;
                lsq_2_exec.forward_byte_en[i] = lsq_2_exec.forward_byte_en[i] >> 24;
            end
            
            // $display("Forward data[%0d]: %0d", i, lsq_2_exec.forward_data[i]);
        end

        for (int unsigned i = 0; i < NUM_FU_LOAD; i++) begin
            lsq_2_exec.forward_en[i] |= forward_ret_2_lsq.forward_en[i];
            if (forward_ret_2_lsq.sq_idx_found[i]) begin
                lsq_2_exec.forward_data[i] = forward_ret_2_lsq.forward_data[i];
                // lsq_2_exec.forward_byte_en[i] = forward_ret_2_lsq.forward_byte_en[i];
                // lsq_2_exec.forward_en[i] = forward_ret_2_lsq.forward_en[i];
            end
            else begin
                // for (int unsigned j = 0, logic [4:0] max = 0, logic [4:0] min = 0; j < 4; j++) begin
                //     if (!lsq_2_exec.forward_byte_en[i][j]) begin
                //         // lsq_2_exec.forward_byte_en[i][j] = forward_ret_2_lsq.forward_byte_en[i][j];
                //         min = 8*j;
                //         max = min + 7;
                //         lsq_2_exec.forward_data[i][min+:7] = forward_ret_2_lsq.forward_data[i][min+:7];
                //     end
                // end
                lsq_2_exec.forward_data[i][7:0] = ~lsq_2_exec.forward_byte_en[i][0] ? forward_ret_2_lsq.forward_data[i][7:0] : lsq_2_exec.forward_data[i][7:0];
                lsq_2_exec.forward_data[i][15:8] = ~lsq_2_exec.forward_byte_en[i][1] ? forward_ret_2_lsq.forward_data[i][15:8] : lsq_2_exec.forward_data[i][15:8];
                lsq_2_exec.forward_data[i][23:16] = ~lsq_2_exec.forward_byte_en[i][2] ? forward_ret_2_lsq.forward_data[i][23:16] : lsq_2_exec.forward_data[i][23:16];
                lsq_2_exec.forward_data[i][31:24] = ~lsq_2_exec.forward_byte_en[i][3] ? forward_ret_2_lsq.forward_data[i][31:24] : lsq_2_exec.forward_data[i][31:24];
            end
            lsq_2_exec.forward_byte_en[i] |= forward_ret_2_lsq.forward_byte_en[i];

            // $display("2. Forward_data[%0d]: %0d, %4b", i, lsq_2_exec.forward_data[i],lsq_2_exec.forward_byte_en[i]);
        end
    end

    ADDR [`NUM_FU_LOAD-1:0] [3:0] bytewise_addr;
    logic [`NUM_FU_LOAD-1:0] [3:0] bytewise_addr_mask;
    logic [`NUM_FU_LOAD-1:0] [1:0] modulo4;
    always_comb begin
        bytewise_addr = '0;
        bytewise_addr_mask = '0;
        modulo4 = '0;

        for (int i = 0; i < `NUM_FU_STORE; i++) begin
            modulo4[i] = exec_2_lsq.st_addr[i] % 4;
            // $display("ADDR: %0d, MOD: %0d, SIZE: %0d", exec_2_lsq.st_addr[i], modulo4[i], exec_2_lsq.st_mem_size[i]);
            for (int j = 0; j < 4; j++) begin
                bytewise_addr[i][j] = exec_2_lsq.st_addr[i] - modulo4[i] + j;
            end
            if (exec_2_lsq.st_mem_size[i] == BYTE) bytewise_addr_mask[i][modulo4[i]] = 1;
            else if (exec_2_lsq.st_mem_size[i] == HALF) bytewise_addr_mask[i][modulo4[i]+:1] = '1;
            else bytewise_addr_mask[i] = '1;

            // $display("bytewise addr[%0d], %0d, %0d, %0d, %0d", exec_2_lsq.st_addr[i], bytewise_addr[i][0], bytewise_addr[i][1], bytewise_addr[i][2], bytewise_addr[i][3]);
            // $display("bytewise mask: %4b", bytewise_addr_mask[i]);
        end

        
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
                cur_idx = exec_2_lsq.st_sq_idx[i];

                if (exec_2_lsq.st_ex_en[i]) begin
                    state[cur_idx].addr <= exec_2_lsq.st_addr[i];
                    state[cur_idx].bytewise_addr <= bytewise_addr[i];
                    state[cur_idx].bytewise_addr_mask <= bytewise_addr_mask[i];
                    state[cur_idx].data <= exec_2_lsq.st_data[i];
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
                    bytewise_addr : '0,
                    bytewise_addr_mask : '0,
                    data   : '0,
                    d_vld     : '0,
                    mem_size : '0
                };
            end

            `ifdef DEBUG
            $display("  %3d | >> LSQ", $time);
            for (int i = 0; i < LSQ_SZ; i++) begin
                $display("Entry [%0d]: id=%0d, rob_idx=%0d, addr=%0d, data=%0d, d_valid=%b, addr mask=%4b",
                i,
                state[i].sq_idx,
                state[i].rob_idx,
                state[i].addr,
                state[i].data,
                state[i].d_vld,
                // state[i].bytewise_addr,
                state[i].bytewise_addr_mask
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
    output forwardRET2lsq forward_ret_2_lsq,
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

    `ifdef DEBUG
    assign state_dbg            = state;
    `endif 
    assign free                 = LSQ_SZ - used;
    assign free_scnt            = `MIN(free, NUM_DPORTS);
    assign used_scnt            = `MIN(used, NUM_RPORTS);

    logic [$clog2(N):0] ret_success;

    logic [NUM_FU_LOAD-1:0] forward_found;
    LSQ_IDX [NUM_FU_LOAD-1:0] forward_idx;
    struct packed {
        ADDR        [NUM_FU_LOAD-1:0]   start;
        ADDR        [NUM_FU_LOAD-1:0]   stop;
        MEM_SIZE    [NUM_FU_LOAD-1:0]   start_sz_req;
    } forward_range;

    
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
        ret_success = ((mem2proc_transaction_tag != 0) && (ret_2_mem.Dmem_command == MEM_STORE)) ? 1 : 0;

    end

    logic [4:0] adj_k;
    logic [1:0] byte_num;
    always_comb begin
        forward_ret_2_lsq = '0;

        //calculate ADDR ranges to search for forwarding
        forward_range = '0;
        for (int unsigned i = 0; i < NUM_FU_LOAD; i++) begin
            forward_range.start[i] = lsq_2_ret.forward_addr[i] - (lsq_2_ret.forward_addr[i] % 4);
            forward_range.stop[i] = forward_range.start[i] + 4;
        end

        //data forwarding
        forward_found = '0;
        forward_idx = '0;
        // for (int unsigned i = 0; i < NUM_FU_LOAD; i++) begin
        //     if (!lsq_2_ret.forward_req_en[i]) continue;

        //     for (int unsigned j = 0, int unsigned idx = 0, int unsigned min = 0, int unsigned max = 0; j < used; ++j) begin
        //         idx = (head+j) % LSQ_SZ;
        //         // $display("Here[%0d,%0d]: %0d == %0d", idx, j, state[idx].sq_idx, lsq_2_ret.forward_sq_idx[i]);
        //         if (state[idx].sq_idx == lsq_2_ret.forward_sq_idx[i]) forward_ret_2_lsq.sq_idx_found[i] = '1;

        //         if (state[idx].d_vld && (forward_range.start[i] <= state[idx].addr) && (state[idx].addr < forward_range.stop[i])) begin
        //             //ensure that the found match and requested forward are big enough to overlap
        //             if (!(((state[idx].addr + state[idx].mem_size) >= lsq_2_ret.forward_addr[i]) 
        //                 || ((lsq_2_ret.forward_addr[i] + lsq_2_ret.forward_mem_size[i]) >= state[idx].mem_size))) continue;

        //             forward_ret_2_lsq.forward_en[i] = '1;

        //             //ensure that the correct bytes are taken from the store that is being forwarded
        //             if (state[idx].addr <= lsq_2_ret.forward_addr[i]) begin
        //                 min = (8 * (lsq_2_ret.forward_addr[i] % 4)) - (8 * (state[idx].addr % 4));
        //                 max = min + (8 * (2**`MIN(state[idx].mem_size,lsq_2_ret.forward_mem_size[i])));
        //             end
        //             else begin
        //                 min = 0;
        //                 max = 8 * (2**`MIN(state[idx].mem_size,lsq_2_ret.forward_mem_size[i]));
        //             end
                    
        //             adj_k = min-(8*(lsq_2_ret.forward_addr[i] % 4))+(8*(state[idx].addr % 4));
        //             byte_num = adj_k / 8;
        //             // $display("adj_k: %0d", adj_k);

        //             if ((max - min) == 8) begin
        //                 forward_ret_2_lsq.forward_data[i][adj_k+:7] = state[idx].data[min+:7];
        //                 forward_ret_2_lsq.forward_byte_en[i][byte_num] = '1;
        //             end
        //             else if ((max - min) == 16) begin
        //                 forward_ret_2_lsq.forward_data[i][adj_k+:15] = state[idx].data[min+:15];
        //                 forward_ret_2_lsq.forward_byte_en[i][byte_num+:1] = '1;
        //             end
        //             else if ((max - min) == 32) begin
        //                 forward_ret_2_lsq.forward_data[i][adj_k+:31] = state[idx].data[min+:31];
        //                 forward_ret_2_lsq.forward_byte_en[i][byte_num+:3] = '1;
        //             end
        //         end
        //         // $display("Return value: %0d", forward_ret_2_lsq.forward_data[i]);
        //         if (state[idx].sq_idx == lsq_2_ret.forward_sq_idx[i]) break;
        //     end
        // end

        for (int unsigned i = 0, ADDR start = 0; i < NUM_FU_LOAD; i++) begin
            if (!lsq_2_ret.forward_req_en[i]) continue;

            start = lsq_2_ret.forward_addr[i] - (lsq_2_ret.forward_addr[i] % 4);
            for (int unsigned j = 0, int unsigned idx = 0, DATA shifted_data = 0, int unsigned offset = 0, logic [1:0] modulo4 = 0; j < used; ++j) begin
                idx = (head+j) % LSQ_SZ;
                modulo4 = state[idx].addr % 4;
                offset = (modulo4 == 0) ? 0 : (modulo4 == 1) ? 8 : (modulo4 == 2) ? 16 : 32;
                shifted_data = state[idx].data << offset;

                if (state[idx].sq_idx == lsq_2_ret.forward_sq_idx[i]) forward_ret_2_lsq.sq_idx_found[i] = '1;

                if (state[idx].d_vld && (state[idx].bytewise_addr[0] == start)) begin
                    // $display("Mask: %4b", state[idx].bytewise_addr_mask);
                    // $display("Addr: %0d, Data: %0d, Shifted: %0d, Offset: %0d", state[idx].addr, state[idx].data, shifted_data, offset);
                    forward_ret_2_lsq.forward_data[i][7:0] = state[idx].bytewise_addr_mask[0] ? shifted_data[7:0] : forward_ret_2_lsq.forward_data[i][7:0];
                    forward_ret_2_lsq.forward_data[i][15:8] = state[idx].bytewise_addr_mask[1] ? shifted_data[15:8] : forward_ret_2_lsq.forward_data[i][15:8];
                    forward_ret_2_lsq.forward_data[i][23:16] = state[idx].bytewise_addr_mask[2] ? shifted_data[23:16] : forward_ret_2_lsq.forward_data[i][23:16];
                    forward_ret_2_lsq.forward_data[i][31:24] = state[idx].bytewise_addr_mask[3] ? shifted_data[31:24] : forward_ret_2_lsq.forward_data[i][31:24];
                    forward_ret_2_lsq.forward_byte_en[i] |= state[idx].bytewise_addr_mask;
                end

                if (state[idx].sq_idx == lsq_2_ret.forward_sq_idx[i]) break;
            end

            forward_ret_2_lsq.forward_en[i] = (forward_ret_2_lsq.forward_byte_en[i] != 0) ? '1 : '0;

            // forward_ret_2_lsq.forward_data[i] = forward_ret_2_lsq.forward_data[i] >> (8*(2**(lsq_2_ret.forward_addr[i] % 4))-8);
            // forward_ret_2_lsq.forward_byte_en[i] = forward_ret_2_lsq.forward_byte_en[i] >> (8*(2**(lsq_2_ret.forward_addr[i] % 4))-8);

            if ((lsq_2_ret.forward_addr[i] % 4) == 1) begin
                forward_ret_2_lsq.forward_data[i] = forward_ret_2_lsq.forward_data[i] >> 8;
                forward_ret_2_lsq.forward_byte_en[i] = forward_ret_2_lsq.forward_byte_en[i] >> 8;
            end
            else if ((lsq_2_ret.forward_addr[i] % 4) == 2) begin
                forward_ret_2_lsq.forward_data[i] = forward_ret_2_lsq.forward_data[i] >> 16;
                forward_ret_2_lsq.forward_byte_en[i] = forward_ret_2_lsq.forward_byte_en[i] >> 16;
            end
            else if ((lsq_2_ret.forward_addr[i] % 4) == 3) begin
                forward_ret_2_lsq.forward_data[i] = forward_ret_2_lsq.forward_data[i] >> 24;
                forward_ret_2_lsq.forward_byte_en[i] = forward_ret_2_lsq.forward_byte_en[i] >> 24;
            end

            // $display("RET Forward data[%0d]: %0d, Addr: %0d, Offset: %0d", i, forward_ret_2_lsq.forward_data[i], lsq_2_ret.forward_addr[i], (8*(2**(lsq_2_ret.forward_addr[i] % 4))-8));
        end
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

            `ifdef DEBUG
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


