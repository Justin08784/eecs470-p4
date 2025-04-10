`include "sys_defs.svh"


module sq #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
    LSQ_SZ_DBL=`LSQ_SZ_DBL,
    NUM_FU_STORE=`NUM_FU_STORE,
    NUM_FU_LOAD=`NUM_FU_LOAD,
    LD_BAY_SZ=`LD_BAY_SZ
) (
    `ifdef DEBUG
    output DBG_sq dbg,
    `endif 
    input clock,
    input reset,
    input flush,

    input dispatch2sq   dis_2_sq,
    input execute2sq    exec_2_sq,
    input executeLD2sq  ld_2_sq,
    input retire2sq     retire_2_sq,
    input MEM_TAG       mem2proc_transaction_tag,

    output sq2dispatch  sq_2_dis,
    output sq2execute   sq_2_exec,
    output sq2rob       sq_2_rob,
    output sq2retire    sq_2_retire,
    output stRET2mem    ret_2_mem
);

    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_ST_PORTS = NUM_FU_STORE; // ex-2-sq ports
    localparam NUM_LD_PORTS = NUM_FU_LOAD;
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(LSQ_SZ)-1:0]      head;
    logic [$clog2(LSQ_SZ)-1:0]      tail;
    logic [$clog2(LSQ_SZ_DBL)-1:0]  tail_dbl;
    LSQ_IDX                         last_used_sq_idx;
    logic                           no_store_yet;

    SQ_ENTRY [LSQ_SZ-1:0]           state;
    logic [$clog2(LSQ_SZ):0]        used, free;
    logic [$clog2(2*`N):0]          rsvd; // sz(rename_buf) = 2*`N

    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;

    sq2stRET sq_2_ret;
    stRET2sq ret_2_sq;
    forwardRET2sq forward_ret_2_sq;

    assign free_scnt    = `MIN(free - rsvd, NUM_DPORTS);
    assign used_scnt    = `MIN(used, NUM_RPORTS);


    DBG_retbuf dbg_retbuf;
    post_ret_buffer buf_dut(
        `ifdef DEBUG
        .dbg(dbg_retbuf),
        `endif
        .clock(clock),
        .reset(reset),
        .sq_2_ret(sq_2_ret),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .ret_2_sq(ret_2_sq),
        .forward_ret_2_sq(forward_ret_2_sq),
        .ret_2_mem(ret_2_mem)
    );


    LSQ_IDX head_plus_one;
    LSQ_IDX [N-1:0] next_ids;
    execute2sq next_complete;
    always_comb begin
        sq_2_rob = '0;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            next_ids[i] = (tail_dbl + i) % LSQ_SZ_DBL;

        // handle dispatch (outs)
        sq_2_dis <= '{
            sq_rdy_scnt         : free_scnt,
            last_used_sq_idx    : last_used_sq_idx,
            next_ids            : next_ids,
            no_store_yet        : no_store_yet
        };

        //handle LSQ CDB to RS
        // sq_2_rs <= '{
        //     en : exec_2_sq.st_ex_en,
        //     sq_idx_cdb     : exec_2_sq.st_sq_idx
        // };

        //handle sq to ROB for retirement
        head_plus_one = (head + 1) % LSQ_SZ;

        sq_2_rob.complete_en = next_complete.st_ex_en;
        for (int i = 0; i < NUM_FU_STORE; i++) begin
            if (i >= next_complete.st_ex_en) continue;

            sq_2_rob.complete_rob_idxs[i] = state[next_complete.st_sq_idx[i]].rob_idx;
        end
        // sq_2_rob.ret_rdy = `MIN(sq_2_rob.ret_rdy,ret_2_sq.free_out);
        sq_2_retire.sq_ret_complete = (ret_2_sq.empty && (used_scnt == 0)) ? '1 : '0;

        //handle retirement write to mem
        sq_2_ret.ret_cnt   = retire_2_sq.r_en;
        sq_2_ret.ret_st[0] = state[head];
        sq_2_ret.ret_st[1] = state[head_plus_one];

    end


    always_comb begin
        sq_2_exec = '0;

        //handle data forwarding
        sq_2_ret.forward_req_en     = ld_2_sq.forward_req_en;
        sq_2_ret.forward_sq_idx     = ld_2_sq.forward_sq_idx;
        sq_2_ret.forward_addr       = ld_2_sq.forward_addr;
        sq_2_ret.forward_mem_size   = ld_2_sq.forward_mem_size;

        for (int unsigned i = 0, ADDR start = 0; i < LD_BAY_SZ; i++) begin

            if (!ld_2_sq.forward_req_en[i]) continue;

            start = ld_2_sq.forward_addr[i] - (ld_2_sq.forward_addr[i] % 4);
            for (int unsigned j = 0, int unsigned idx = 0; j < used; ++j) begin
                idx = (head+j) % LSQ_SZ;

                if (state[idx].d_vld && ({state[idx].addr[31:2],2'b0} == start)) begin
                    sq_2_exec.forward_data[i][7:0]      = state[idx].bytewise_addr_mask[0] ? state[idx].data[7:0]      : sq_2_exec.forward_data[i][7:0];
                    sq_2_exec.forward_data[i][15:8]     = state[idx].bytewise_addr_mask[1] ? state[idx].data[15:8]     : sq_2_exec.forward_data[i][15:8];
                    sq_2_exec.forward_data[i][23:16]    = state[idx].bytewise_addr_mask[2] ? state[idx].data[23:16]    : sq_2_exec.forward_data[i][23:16];
                    sq_2_exec.forward_data[i][31:24]    = state[idx].bytewise_addr_mask[3] ? state[idx].data[31:24]    : sq_2_exec.forward_data[i][31:24];

                    sq_2_exec.forward_byte_en[i] |= state[idx].bytewise_addr_mask;
                end

                if (state[idx].sq_idx == ld_2_sq.forward_sq_idx[i]) break;
            end

            sq_2_exec.forward_en[i] = (sq_2_exec.forward_byte_en[i] != 0) ? '1 : '0;
        end

        for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
            sq_2_exec.forward_en[i] |= forward_ret_2_sq.forward_en[i];
            if (forward_ret_2_sq.sq_idx_found[i]) begin
                sq_2_exec.forward_data[i] = forward_ret_2_sq.forward_data[i];
            end
            else begin
                sq_2_exec.forward_data[i][7:0]      = ~sq_2_exec.forward_byte_en[i][0] ? forward_ret_2_sq.forward_data[i][7:0]      : sq_2_exec.forward_data[i][7:0];
                sq_2_exec.forward_data[i][15:8]     = ~sq_2_exec.forward_byte_en[i][1] ? forward_ret_2_sq.forward_data[i][15:8]     : sq_2_exec.forward_data[i][15:8];
                sq_2_exec.forward_data[i][23:16]    = ~sq_2_exec.forward_byte_en[i][2] ? forward_ret_2_sq.forward_data[i][23:16]    : sq_2_exec.forward_data[i][23:16];
                sq_2_exec.forward_data[i][31:24]    = ~sq_2_exec.forward_byte_en[i][3] ? forward_ret_2_sq.forward_data[i][31:24]    : sq_2_exec.forward_data[i][31:24];
            end
            sq_2_exec.forward_byte_en[i] |= forward_ret_2_sq.forward_byte_en[i];

            if ((ld_2_sq.forward_addr[i] % 4) == 1) begin
                sq_2_exec.forward_data[i]       = sq_2_exec.forward_data[i] >> 8;
                sq_2_exec.forward_byte_en[i]    = sq_2_exec.forward_byte_en[i] >> 8;
            end
            else if ((ld_2_sq.forward_addr[i] % 4) == 2) begin
                sq_2_exec.forward_data[i]       = sq_2_exec.forward_data[i] >> 16;
                sq_2_exec.forward_byte_en[i]    = sq_2_exec.forward_byte_en[i] >> 16;
            end
            else if ((ld_2_sq.forward_addr[i] % 4) == 3) begin
                sq_2_exec.forward_data[i]       = sq_2_exec.forward_data[i] >> 24;
                sq_2_exec.forward_byte_en[i]    = sq_2_exec.forward_byte_en[i] >> 24;
            end

            //ensure don't accidentally give more data than it wants
            if (ld_2_sq.forward_mem_size[i] == BYTE) begin
                sq_2_exec.forward_data[i] &= 8'hFF;
                sq_2_exec.forward_byte_en[i] &= 1'b1;
            end
            else if (ld_2_sq.forward_mem_size[i] == HALF) begin
                sq_2_exec.forward_data[i] &= 16'hFFFF;
                sq_2_exec.forward_byte_en[i] &= 2'b11;
            end

        end
    end

    logic [`NUM_FU_STORE-1:0] [3:0] bytewise_addr_mask;
    logic [`NUM_FU_STORE-1:0] [1:0] modulo4;
    always_comb begin
        bytewise_addr_mask = '0;
        modulo4 = '0;

        for (int i = 0; i < `NUM_FU_STORE; i++) begin
            modulo4[i] = exec_2_sq.st_addr[i] % 4;

            if (exec_2_sq.st_mem_size[i] == BYTE)       bytewise_addr_mask[i][modulo4[i]] = 1;
            else if (exec_2_sq.st_mem_size[i] == HALF)  bytewise_addr_mask[i][modulo4[i]+:1] = '1;
            else                                        bytewise_addr_mask[i] = '1;
        end

        
    end

    logic [`NUM_FU_STORE-1:0] [4:0] updateOffset;
    always_comb begin
        updateOffset = '0;

        for (int i = 0, logic [1:0] modulo4 = 0; i < `NUM_FU_STORE; i++) begin
            modulo4 = exec_2_sq.st_addr[i] % 4;
            updateOffset[i] = (modulo4 == 0) ? 0 : (modulo4 == 1) ? 8 : (modulo4 == 2) ? 16 : 24;
            // shifted_data = state[idx].data << offset;
        end
    end


    always_ff @(posedge clock) begin
        
        if (reset || flush) begin
            used    <= 0;
            free    <= LSQ_SZ;
            rsvd    <= 0;

            head    <= 0;
            tail    <= 0;
            tail_dbl <= 0;
            state   <= '0;
            last_used_sq_idx <= LSQ_SZ_DBL - 1; //outside of SQ range so that if a load occurs before the first store we don't flag it falsely
            next_complete <= '0;
            no_store_yet <= '1;
        end else begin
            used    <= used + dis_2_sq.sq_d_en_cnt - retire_2_sq.r_en;
            free    <= free - dis_2_sq.sq_d_en_cnt + retire_2_sq.r_en;
            rsvd    <= rsvd - dis_2_sq.sq_d_en_cnt + dis_2_sq.rename_en_cnt;

            head    <= (head + retire_2_sq.r_en) % LSQ_SZ;
            tail    <= (tail + dis_2_sq.sq_d_en_cnt) % LSQ_SZ;
            tail_dbl <= (tail_dbl + dis_2_sq.sq_d_en_cnt) % LSQ_SZ_DBL;
            last_used_sq_idx <= dis_2_sq.sq_d_en_cnt > 0 ? (last_used_sq_idx + dis_2_sq.sq_d_en_cnt) % LSQ_SZ_DBL : last_used_sq_idx;
            no_store_yet <= (dis_2_sq.sq_d_en_cnt > 0) | no_store_yet;

            next_complete <= exec_2_sq;

            //to ROB
            // if (state[head].d_vld && state[head_plus_one].d_vld)    sq_2_retire.ret_rdy <= 2;
            // else if (state[head].d_vld)                             sq_2_retire.ret_rdy <= 1;
            // else                                                    sq_2_retire.ret_rdy <= 0;
            // // sq_2_retire.ret_rdy = `MIN(sq_2_retire.ret_rdy,ret_2_sq.free_out);
            // sq_2_retire.sq_ret_complete <= sq_ret_complete;
            
            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
                cur_idx = exec_2_sq.st_sq_idx[i];
                
                if (exec_2_sq.st_ex_en[i]) begin
                    state[cur_idx].addr                 <= exec_2_sq.st_addr[i];
                    state[cur_idx].bytewise_addr_mask   <= bytewise_addr_mask[i];
                    state[cur_idx].data                 <= (exec_2_sq.st_data[i] << updateOffset[i]);
                    state[cur_idx].mem_size             <= exec_2_sq.st_mem_size[i];
                    state[cur_idx].d_vld                <= '1;
                end

            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= dis_2_sq.sq_d_en_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    sq_idx              : next_ids[i],
                    rob_idx             : dis_2_sq.rob_idx[i],
                    addr                : '0,
                    bytewise_addr_mask  : '0,
                    data                : '0,
                    d_vld               : '0,
                    mem_size            : '0
                };
            end

        end
    end


    `ifdef DEBUG
    assign dbg = '{
        // internal state
        state,
        head,
        tail,
        used,
        // I/O
        dis_2_sq,
        exec_2_sq,
        retire_2_sq,
        mem2proc_transaction_tag,

        sq_2_dis,
        sq_2_exec,
        // sq2rs sq_2_rs,
        sq_2_retire,
        ret_2_mem,

        dbg_retbuf
    };
    `endif


endmodule


module post_ret_buffer #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
    LSQ_SZ_DBL=`LSQ_SZ_DBL,
    NUM_FU_STORE=`NUM_FU_STORE,
    NUM_FU_LOAD=`NUM_FU_LOAD,
    LD_BAY_SZ=`LD_BAY_SZ
) (
    `ifdef DEBUG
    output DBG_retbuf dbg,
    `endif
    input clock,
    input reset,

    input sq2stRET sq_2_ret,
    input MEM_TAG mem2proc_transaction_tag,

    output stRET2sq ret_2_sq,
    output forwardRET2sq forward_ret_2_sq,
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

    assign free                 = LSQ_SZ - used;
    assign free_scnt            = `MIN(free, NUM_DPORTS);
    assign used_scnt            = `MIN(used, NUM_RPORTS);

    logic ret_success;
    logic [1:0] writeMod;
    logic [4:0] writeOffset;
    always_comb begin
        ret_2_sq = '0;
        writeMod = '0;
        writeOffset = '0;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;

        // handle ret_2_sq
        ret_2_sq.free_out = free_scnt;//`MIN(free, NUM_DPORTS);
        ret_2_sq.empty = (used_scnt == 0) ? '1 : '0;

        //handle retirement write to mem
        ret_2_mem = '0;
        if (head != tail) begin
            writeMod = state[head].addr % 4;
            writeOffset = (writeMod == 0) ? 0 : (writeMod == 1) ? 8 : (writeMod == 2) ? 16 : 24;

            ret_2_mem.Dmem_command      = MEM_STORE;
            ret_2_mem.Dmem_addr         = state[head].addr;
            ret_2_mem.Dmem_store_data   = (state[head].data >> writeOffset);
            ret_2_mem.Dmem_size         = state[head].mem_size;
        end
        ret_success = ((mem2proc_transaction_tag != 0) && (ret_2_mem.Dmem_command == MEM_STORE)) ? 1 : 0;

    end


    always_comb begin
        forward_ret_2_sq = '0;

        for (int unsigned i = 0, ADDR start = 0; i < LD_BAY_SZ; i++) begin
            if (!sq_2_ret.forward_req_en[i]) continue;

            start = sq_2_ret.forward_addr[i] - (sq_2_ret.forward_addr[i] % 4);
            for (int unsigned j = 0, int unsigned idx = 0; j < used; ++j) begin
                idx = (head+j) % LSQ_SZ;

                if (state[idx].sq_idx == sq_2_ret.forward_sq_idx[i]) forward_ret_2_sq.sq_idx_found[i] = '1;

                if (state[idx].d_vld && ({state[idx].addr[31:2],2'b0} == start)) begin
                    forward_ret_2_sq.forward_data[i][7:0]   = state[idx].bytewise_addr_mask[0] ? state[idx].data[7:0]      : forward_ret_2_sq.forward_data[i][7:0];
                    forward_ret_2_sq.forward_data[i][15:8]  = state[idx].bytewise_addr_mask[1] ? state[idx].data[15:8]     : forward_ret_2_sq.forward_data[i][15:8];
                    forward_ret_2_sq.forward_data[i][23:16] = state[idx].bytewise_addr_mask[2] ? state[idx].data[23:16]    : forward_ret_2_sq.forward_data[i][23:16];
                    forward_ret_2_sq.forward_data[i][31:24] = state[idx].bytewise_addr_mask[3] ? state[idx].data[31:24]    : forward_ret_2_sq.forward_data[i][31:24];


                    forward_ret_2_sq.forward_byte_en[i] |= state[idx].bytewise_addr_mask;
                end

                if (state[idx].sq_idx == sq_2_ret.forward_sq_idx[i]) break;
            end

            forward_ret_2_sq.forward_en[i] = (forward_ret_2_sq.forward_byte_en[i] != 0) ? '1 : '0;
        end
    end


    always_ff @(posedge clock) begin
        if (reset) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            state   <= '0;
        end else begin
            used    <= used + sq_2_ret.ret_cnt - ret_success;
            head    <= (head + ret_success) % LSQ_SZ;
            tail    <= (tail + sq_2_ret.ret_cnt) % LSQ_SZ;

            // handle sq to ret buffer (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= sq_2_ret.ret_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= sq_2_ret.ret_st[i];
            end

        end
    end

    `ifdef DEBUG
    assign dbg = '{ 
        // internal state
        state,
        head,
        tail,
        used,
        // I/O
        sq_2_ret,
        mem2proc_transaction_tag,

        ret_2_sq,
        forward_ret_2_sq,
        ret_2_mem
    };
    `endif

endmodule


