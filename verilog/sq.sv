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

    input dispatch2sq   dispatch_in,
    input execute2sq    execute_in,
    input executeLD2sq  ex_frwd_in,
    input retire2sq     retire_in,
    input MEM_TAG       mem2proc_transaction_tag,

    output sq2dispatch  dispatch_out,
    output sq2execute   execute_out,
    output sq2rob       rob_out,
    output sq2retire    retire_out,
    output stRET2mem    mem_out
);

    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_ST_PORTS = NUM_FU_STORE; // ex-2-sq ports
    localparam NUM_LD_PORTS = NUM_FU_LOAD;

    logic [$clog2(LSQ_SZ)-1:0]      head;
    logic [$clog2(LSQ_SZ)-1:0]      tail;
    logic [$clog2(LSQ_SZ_DBL)-1:0]  tail_dbl;
    LSQ_IDX                         last_used_sq_idx;
    logic                           no_store_yet;

    SQ_ENTRY [LSQ_SZ-1:0]           state;
    logic [$clog2(LSQ_SZ):0]        used, free;
    logic [$clog2(2*`N):0]          rsvd; // sz(rename_buf) = 2*`N

    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;
    assign free_scnt    = `MIN(free - rsvd, NUM_DPORTS);
    assign used_scnt    = `MIN(used, NUM_RPORTS);

    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;
    LSQ_IDX [N-1:0] next_ids;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            next_ids[i] = (tail_dbl + i) % LSQ_SZ_DBL;
    end


    /* >> ======== SECTION: Retirement ======== >> */
    execute2sq      next_complete;
    sq2stRET        ret_buf_out;
    stRET2sq        ret_buf_in;
    DBG_retbuf      dbg_retbuf;
    forwardRET2sq   ret_buf_frwd_in;
    post_ret_buffer buf_dut(
        `ifdef DEBUG
        .dbg(dbg_retbuf),
        `endif
        .clock(clock),
        .reset(reset),
        .sq_in(ret_buf_out),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .sq_out(ret_buf_in),
        .sq_frwd_out(ret_buf_frwd_in),
        .mem_out(mem_out)
    );

    always_comb begin
        rob_out = '0;
        //handle sq to ROB for retirement
        rob_out.complete_en = next_complete.st_ex_en;
        for (int i = 0; i < NUM_FU_STORE; i++) begin
            if (i >= next_complete.st_ex_en)
                continue;

            rob_out.complete_rob_idxs[i] = state[next_complete.st_sq_idx[i]].rob_idx;
        end
        retire_out.sq_ret_complete = (ret_buf_in.used_scnt == 0) && (used_scnt == 0);

        //handle retirement write to mem
        ret_buf_out.ret_cnt    = retire_in.r_en;
        foreach (r_idxs[i])
            ret_buf_out.ret_st[i] = state[r_idxs[i]];

        //handle data forwarding
        ret_buf_out.forward_req_en     = ex_frwd_in.forward_req_en;
        ret_buf_out.forward_sq_idx     = ex_frwd_in.forward_sq_idx;
        ret_buf_out.forward_addr       = ex_frwd_in.forward_addr;
        ret_buf_out.forward_mem_size   = ex_frwd_in.forward_mem_size;
    end

    /* >> ======== SECTION: Execute ======== >> */
    sq2execute next_sq_2_exec;
    sq2execute uncombined_forward_data;

    // always_comb begin
    //     next_sq_2_exec = '0;
    //     // most_recent_bytes = '0;

    //     for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin

    //         if (!ex_frwd_in.forward_req_en[i]) continue;

    //         for (int unsigned j = 0, int unsigned idx = 0; j < used; ++j) begin
    //             idx = (head+j) % LSQ_SZ;

    //             if (state[idx].d_vld && (waddr(state[idx].addr) == waddr(ex_frwd_in.forward_addr[i]))) begin
    //                 next_sq_2_exec.forward_data[i].byte_level[0] = state[idx].bytewise_addr_mask[0] ? state[idx].data.byte_level[0] : next_sq_2_exec.forward_data[i].byte_level[0];
    //                 next_sq_2_exec.forward_data[i].byte_level[1] = state[idx].bytewise_addr_mask[1] ? state[idx].data.byte_level[1] : next_sq_2_exec.forward_data[i].byte_level[1];
    //                 next_sq_2_exec.forward_data[i].byte_level[2] = state[idx].bytewise_addr_mask[2] ? state[idx].data.byte_level[2] : next_sq_2_exec.forward_data[i].byte_level[2];
    //                 next_sq_2_exec.forward_data[i].byte_level[3] = state[idx].bytewise_addr_mask[3] ? state[idx].data.byte_level[3] : next_sq_2_exec.forward_data[i].byte_level[3];

    //                 next_sq_2_exec.forward_byte_en[i] |= state[idx].bytewise_addr_mask;
    //             end

    //             if (state[idx].sq_idx == ex_frwd_in.forward_sq_idx[i]) break;
    //         end

    //         next_sq_2_exec.forward_en[i] = (next_sq_2_exec.forward_byte_en[i] != 0);

    //     end
    // end

    logic [LD_BAY_SZ-1:0] idx_found;
    LSQ_IDX [LD_BAY_SZ-1:0] matching_idx;
    logic [LD_BAY_SZ-1:0] [LSQ_SZ-1:0] match_mask;
    // always_comb begin
        // idx_found = '0;
        // matching_idx = '0;
        // match_mask = '0;
        // for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
        //     for (int unsigned j = 0, LSQ_IDX idx = 0; j < LSQ_SZ; j++) begin
        //         idx = (head+j) % LSQ_SZ;
        //         match_mask[i][idx] = 1;
        //         if (state[idx].d_vld && (state[idx].sq_idx == ex_frwd_in.forward_sq_idx[i])) begin
        //             matching_idx[i] = idx;
        //             idx_found[i] = 1;
        //             break;
        //         end
        //     end

        //     if (!idx_found[i]) match_mask[i] = '0;
        // end

        // for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin //can be turned into a generate
        //     matching_idx[i] = ex_frwd_in.forward_sq_idx[i] % LSQ_SZ;
        //     if (state[matching_idx[i]].d_vld && (state[matching_idx[i]].sq_idx == ex_frwd_in.forward_sq_idx[i])) idx_found[i] = 1;
        //     else idx_found[i] = 0;
        // end

        // for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
        //     for (int unsigned j = 0; j < LSQ_SZ; j++) begin
        //         if ((matching_idx[i] < head) && ((j <= matching_idx[i]) || (j >= head))) begin
        //             match_mask[i][j] = 1;
        //         end
        //         else if ((j >= head) && (j <= matching_idx[i])) begin
        //             match_mask[i][j] = 1;
        //         end
        //         else match_mask[i][j] = 0;
        //     end
        // end
    // end

    logic [LD_BAY_SZ-1:0] [3:0] [LSQ_SZ-1:0] byte_matches;
    logic [LD_BAY_SZ-1:0] [3:0] [LSQ_SZ-1:0] shifted_matches;
    logic [LD_BAY_SZ-1:0] [3:0] [LSQ_SZ-1:0] final_matches;

    genvar i,j,k,l;
    generate
        for (i = 0; i < LD_BAY_SZ; i++) begin : find_bay_matches

            assign matching_idx[i] = ex_frwd_in.forward_sq_idx[i] % LSQ_SZ;
            assign idx_found[i] = (state[matching_idx[i]].d_vld & (state[matching_idx[i]].sq_idx == ex_frwd_in.forward_sq_idx[i])) ? 1 : 0;

            for (l = 0; l < LSQ_SZ; l++) begin : find_match_mask
                assign match_mask[i][l] = ((matching_idx[i] < head) & ((l <= matching_idx[i]) || (l >= head))) || ((l >= head) && (l <= matching_idx[i])) ? 1 : 0;
            end
            

            for (j = 0; j < 4; j++) begin : find_byte_matches
                for (k = 0; k < LSQ_SZ; k++) begin : find_table_matches
                    assign byte_matches[i][j][k] = state[k].d_vld & (waddr(state[k].addr) == waddr(ex_frwd_in.forward_addr[i])) ? state[k].bytewise_addr_mask[j] & match_mask[i][k] : '0;
                end

                psel_gen #(
                .WIDTH  (LSQ_SZ),
                .REQS   (1)
                ) sel (
                    .req    (byte_matches[i][j]),
                    .gnt_bus(shifted_matches[i][j])
                );
                assign final_matches[i][j] = rotate_right(shifted_matches[i][j],matching_idx[i]);
                assign next_sq_2_exec.forward_data[i].byte_level[j] = idx_found[i] ? state[encode_idx(final_matches[i][j])].data.byte_level[j] : '0;
                assign next_sq_2_exec.forward_byte_en[i][j] = idx_found[i] ? state[encode_idx(rotate_right(shifted_matches[i][j],matching_idx[i]))].bytewise_addr_mask[j] : '0;//1;
                    
            end

            assign next_sq_2_exec.forward_en[i] = (next_sq_2_exec.forward_byte_en[i] != 0);
        end
    endgenerate

    // genvar i,j,k;
    // generate
    //     for (i = 0; i < LD_BAY_SZ; i++) begin : find_byte_matches_1
    //         for (j = 0; j < 4; j++) begin : find_byte_matches_2
    //             for (k = 0; k < LSQ_SZ; k++) begin : find_byte_matches_3
    //                 assign byte_matches[i][j][k] = state[k].d_vld & (waddr(state[k].addr) == waddr(ex_frwd_in.forward_addr[i])) ? state[k].bytewise_addr_mask[j] & match_mask[i][k] : '0;
    //             end
    //         end
    //     end
    // endgenerate

    // genvar a,b;
    // generate
    //     for (a = 0; a < LD_BAY_SZ; a++) begin : find_most_recent_match_1
    //         for (b = 0; b < 4; b++) begin : find_most_recent_match_2
    //             psel_gen #(
    //             .WIDTH  (LSQ_SZ),
    //             .REQS   (1)
    //             ) sel (
    //                 .req    (rotate_left(byte_matches[a][b],matching_idx[a])),
    //                 .gnt_bus(shifted_matches[a][b])
    //             );
    //         end
    //     end
    // endgenerate

    // always_comb begin
    //     for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
    //         for (int unsigned j = 0; j < 4; j++) begin
    //             final_matches[i][j] = rotate_right(shifted_matches[i][j],matching_idx[i]) & match_mask[i];
    //             // $display("FINAL_MASK[%0d][%0d], %b", i, j, final_matches[i][j]);
    //         end
    //     end
    // end

    // generate
    //     // next_sq_2_exec = '0;
    //     for (i = 0; i < LD_BAY_SZ; i++) begin : assign_next_forward_1
    //         for (j = 0; j < 4; j++) begin : assign_next_forward_2
    //                 // assign idx = encode_idx(rotate_right(shifted_matches[i][j],matching_idx[i]));
    //                 assign next_sq_2_exec.forward_data[i].byte_level[j] = idx_found[i] ? state[encode_idx(rotate_right(shifted_matches[i][j],matching_idx[i]))].data.byte_level[j] : '0;
    //                 assign next_sq_2_exec.forward_byte_en[i][j] = idx_found[i] ? state[encode_idx(rotate_right(shifted_matches[i][j],matching_idx[i]))].bytewise_addr_mask[j] : '0;//1;
                    
    //         end
    //         assign next_sq_2_exec.forward_en[i] = (next_sq_2_exec.forward_byte_en[i] != 0);
    //         // $display("FORWARD_DATA[%0d]: %0d, en: %b, mask: %4b", i, next_sq_2_exec.forward_data[i], next_sq_2_exec.forward_en[i], next_sq_2_exec.forward_byte_en[i]);
    //     end
    // endgenerate

    //Combine SQ and RET_BUF matches

    always_comb begin
        execute_out = '0;
        for (int unsigned i = 0, int unsigned word_off = 0; i < LD_BAY_SZ; i++) begin
            execute_out.forward_en[i] |= ret_buf_frwd_in.forward_en[i];
            if (ret_buf_frwd_in.sq_idx_found[i]) begin
                execute_out.forward_data[i] = ret_buf_frwd_in.forward_data[i];
                execute_out.forward_byte_en[i] = ret_buf_frwd_in.forward_byte_en[i];
            end
            else begin
                execute_out.forward_data[i].byte_level[0] = uncombined_forward_data.forward_byte_en[i][0] ? uncombined_forward_data.forward_data[i].byte_level[0] : ret_buf_frwd_in.forward_data[i].byte_level[0];
                execute_out.forward_data[i].byte_level[1] = uncombined_forward_data.forward_byte_en[i][1] ? uncombined_forward_data.forward_data[i].byte_level[1] : ret_buf_frwd_in.forward_data[i].byte_level[1];
                execute_out.forward_data[i].byte_level[2] = uncombined_forward_data.forward_byte_en[i][2] ? uncombined_forward_data.forward_data[i].byte_level[2] : ret_buf_frwd_in.forward_data[i].byte_level[2];
                execute_out.forward_data[i].byte_level[3] = uncombined_forward_data.forward_byte_en[i][3] ? uncombined_forward_data.forward_data[i].byte_level[3] : ret_buf_frwd_in.forward_data[i].byte_level[3];
                execute_out.forward_byte_en[i] |= ret_buf_frwd_in.forward_byte_en[i];
            end
            
            word_off = iw_off(ex_frwd_in.forward_addr[i]);
            execute_out.forward_data[i]       >>= 8 * word_off;
            execute_out.forward_byte_en[i]    >>= 8 * word_off;

            //ensure don't accidentally give more data than it wants
            case (ex_frwd_in.forward_mem_size[i])
                BYTE: begin
                    execute_out.forward_data[i]       &= 8'hFF;
                    execute_out.forward_byte_en[i]    &= 1'b1;
                end
                HALF: begin
                    execute_out.forward_data[i]       &= 16'hFFFF;
                    execute_out.forward_byte_en[i]    &= 2'b11;
                end
                default: begin
                    execute_out.forward_data[i]       = execute_out.forward_data[i];//&= 32'hFFFFFFFF; 
                    execute_out.forward_byte_en[i]    = execute_out.forward_byte_en[i];//&= 4'b1111;
                end
            endcase

        end
    end

    logic [`NUM_FU_STORE-1:0] [3:0] bytewise_addr_mask;
    always_comb begin
        bytewise_addr_mask = '0;

        for (int i = 0, int unsigned word_off = 0; i < `NUM_FU_STORE; i++) begin
            word_off = iw_off(execute_in.st_addr[i]);

            case (execute_in.st_mem_size[i])
                BYTE:   bytewise_addr_mask[i][word_off]     = 1;
                HALF:   bytewise_addr_mask[i][word_off+:1]  = '1;
                default:bytewise_addr_mask[i]               = '1;
            endcase
        end

        
    end

    logic [`NUM_FU_STORE-1:0] [4:0] updateOffset;
    always_comb begin
        updateOffset = '0;
        for (int i = 0; i < `NUM_FU_STORE; i++)
            updateOffset[i] = 8 * iw_off(execute_in.st_addr[i]);
    end

    /* >> ======== SECTION: Dispatch ======== >> */
    always_comb begin
        // handle dispatch (outs)
        dispatch_out = '{
            sq_rdy_scnt         : free_scnt,
            last_used_sq_idx    : last_used_sq_idx,
            next_ids            : next_ids,
            no_store_yet        : no_store_yet
        };
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
            uncombined_forward_data <= '0;
        end else begin
            used    <= used + dispatch_in.sq_d_en_cnt - retire_in.r_en;
            free    <= free - dispatch_in.sq_d_en_cnt + retire_in.r_en;
            rsvd    <= rsvd - dispatch_in.sq_d_en_cnt + dispatch_in.rename_en_cnt;

            head    <= (head + retire_in.r_en) % LSQ_SZ;
            tail    <= (tail + dispatch_in.sq_d_en_cnt) % LSQ_SZ;
            tail_dbl <= (tail_dbl + dispatch_in.sq_d_en_cnt) % LSQ_SZ_DBL;
            last_used_sq_idx <= dispatch_in.sq_d_en_cnt > 0 ? (last_used_sq_idx + dispatch_in.sq_d_en_cnt) % LSQ_SZ_DBL : last_used_sq_idx;
            no_store_yet <= (dispatch_in.sq_d_en_cnt > 0) ? 0 : no_store_yet;

            // $display("LAST_USED: %0d, %b", last_used_sq_idx, no_store_yet);

            next_complete <= execute_in;
            uncombined_forward_data <= next_sq_2_exec;

            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
                cur_idx = execute_in.st_sq_idx[i];
                
                if (execute_in.st_ex_en[i]) begin
                    state[cur_idx].addr                 <= execute_in.st_addr[i];
                    state[cur_idx].bytewise_addr_mask   <= bytewise_addr_mask[i];
                    state[cur_idx].data                 <= (execute_in.st_data[i] << updateOffset[i]);
                    state[cur_idx].mem_size             <= execute_in.st_mem_size[i];
                    state[cur_idx].d_vld                <= '1;
                end

            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= dispatch_in.sq_d_en_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    sq_idx              : next_ids[i],
                    rob_idx             : dispatch_in.rob_idx[i],
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
        dispatch_in,
        execute_in,
        retire_in,
        mem2proc_transaction_tag,

        dispatch_out,
        execute_out,
        // sq2rs sq_2_rs,
        retire_out,
        mem_out,

        dbg_retbuf
    };
    `endif

    function automatic logic [LSQ_SZ-1:0] rotate_left;
        input logic [LSQ_SZ-1:0] data;
        input int unsigned shift;
        begin
            rotate_left = (data << shift) | (data >> shift);
        end
    endfunction

    function automatic logic [LSQ_SZ-1:0] rotate_right;
        input logic [LSQ_SZ-1:0] data;
        input int unsigned shift;
        begin
            rotate_right = (data >> shift) | (data << shift);
        end
    endfunction

    function automatic LSQ_IDX encode_idx;
        input logic [LSQ_SZ-1:0] data;
        begin
            case (data)
                16'b0000000000000001 : encode_idx = 5'd0;
                16'b0000000000000010 : encode_idx = 5'd1;
                16'b0000000000000100 : encode_idx = 5'd2;
                16'b0000000000001000 : encode_idx = 5'd3;
                16'b0000000000010000 : encode_idx = 5'd4;
                16'b0000000000100000 : encode_idx = 5'd5;
                16'b0000000001000000 : encode_idx = 5'd6;
                16'b0000000010000000 : encode_idx = 5'd7;
                16'b0000000100000000 : encode_idx = 5'd8;
                16'b0000001000000000 : encode_idx = 5'd9;
                16'b0000010000000000 : encode_idx = 5'd10;
                16'b0000100000000000 : encode_idx = 5'd11;
                16'b0001000000000000 : encode_idx = 5'd12;
                16'b0010000000000000 : encode_idx = 5'd13;
                16'b0100000000000000 : encode_idx = 5'd14;
                16'b1000000000000000 : encode_idx = 5'd15;
                default: encode_idx = 5'd0;
            endcase
        end
    endfunction


endmodule


module post_ret_buffer #(parameter 
    N=`N,
    SQ_RET_BUF_SZ=`SQ_RET_BUF_SZ,
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

    input sq2stRET sq_in,
    input MEM_TAG mem2proc_transaction_tag,

    output stRET2sq sq_out,
    output forwardRET2sq sq_frwd_out,
    output stRET2mem mem_out
);

    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_ST_PORTS = NUM_FU_STORE; // ex-2-sq ports
    localparam NUM_LD_PORTS = NUM_FU_LOAD;
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(SQ_RET_BUF_SZ)-1:0]  head;
    logic [$clog2(SQ_RET_BUF_SZ)-1:0]  tail;

    SQ_ENTRY [SQ_RET_BUF_SZ-1:0]       state;
    logic [$clog2(SQ_RET_BUF_SZ):0]    used, free;

    logic [NUM_RPORTS-1:0][$clog2(SQ_RET_BUF_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(SQ_RET_BUF_SZ)-1:0] d_idxs;

    forwardRET2sq next_forward_ret_2_sq;

    assign free                 = SQ_RET_BUF_SZ - used;
    assign free_scnt            = `MIN(free, NUM_DPORTS);
    assign used_scnt            = `MIN(used, NUM_RPORTS);

    logic [$clog2(N):0] ret_success;
    // logic [4:0] writeOffset;

    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % SQ_RET_BUF_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % SQ_RET_BUF_SZ;
    end

    always_comb begin
        // handle sq_out
        sq_out.free_scnt  = free_scnt;
        sq_out.used_scnt  = used_scnt;
    end

    always_comb begin
        //handle retirement write to mem
        mem_out = '0;

        // if (used_scnt != 0) begin
        //     writeOffset = 8 * iw_off(state[head].addr);

        //     mem_out.Dmem_command      = MEM_STORE;
        //     mem_out.Dmem_addr         = state[head].addr;
        //     mem_out.Dmem_store_data   = (state[head].data >> writeOffset);
        //     mem_out.Dmem_size         = state[head].mem_size;
        // end
        // ret_success = ((mem2proc_transaction_tag != 0) && (mem_out.Dmem_command[0] == MEM_STORE)) ? 1 : 0;

        for (int unsigned i = 0; i < N; ++i) begin
            if (i >= used_scnt) continue;
            
            // writeOffset = 8 * iw_off(state[r_idxs[i]].addr);
            mem_out.Dmem_command[i]      = MEM_STORE;
            mem_out.Dmem_addr[i]         = state[r_idxs[i]].addr;
            mem_out.Dmem_store_data[i]   = (state[r_idxs[i]].data >> (8 * iw_off(state[r_idxs[i]].addr)));
            mem_out.Dmem_size[i]         = state[r_idxs[i]].mem_size;
        end
        ret_success = ((mem2proc_transaction_tag != 0) && (mem_out.Dmem_command[0] == MEM_STORE));
        // ret_success = mem2proc_transaction_tag; <--TODO: swap to this line once teh SQ retirement buffer is pointing at the superscalar dcache instead of mem
    end

    // always_comb begin
    //     next_forward_ret_2_sq = '0;
    //     // most_recent_bytes = '0;

    //     for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
    //         if (!sq_in.forward_req_en[i]) continue;

    //         for (int unsigned j = 0, int unsigned idx = 0; j < used; ++j) begin
    //             idx = (head+j) % SQ_RET_BUF_SZ;

    //             if (state[idx].sq_idx == sq_in.forward_sq_idx[i]) next_forward_ret_2_sq.sq_idx_found[i] = '1;

    //             if (state[idx].d_vld && (waddr(state[idx].addr) == waddr(sq_in.forward_addr[i]))) begin
    //                 next_forward_ret_2_sq.forward_data[i].byte_level[0] = state[idx].bytewise_addr_mask[0] ? state[idx].data.byte_level[0] : next_forward_ret_2_sq.forward_data[i].byte_level[0];
    //                 next_forward_ret_2_sq.forward_data[i].byte_level[1] = state[idx].bytewise_addr_mask[1] ? state[idx].data.byte_level[1] : next_forward_ret_2_sq.forward_data[i].byte_level[1];
    //                 next_forward_ret_2_sq.forward_data[i].byte_level[2] = state[idx].bytewise_addr_mask[2] ? state[idx].data.byte_level[2] : next_forward_ret_2_sq.forward_data[i].byte_level[2];
    //                 next_forward_ret_2_sq.forward_data[i].byte_level[3] = state[idx].bytewise_addr_mask[3] ? state[idx].data.byte_level[3] : next_forward_ret_2_sq.forward_data[i].byte_level[3];


    //                 next_forward_ret_2_sq.forward_byte_en[i] |= state[idx].bytewise_addr_mask;
    //             end

    //             if (state[idx].sq_idx == sq_in.forward_sq_idx[i]) break;
    //         end

    //         next_forward_ret_2_sq.forward_en[i] = (next_forward_ret_2_sq.forward_byte_en[i] != 0);

    //     end
    // end


    logic [LD_BAY_SZ-1:0] idx_found;
    LSQ_IDX [LD_BAY_SZ-1:0] matching_idx;
    logic [LD_BAY_SZ-1:0] [SQ_RET_BUF_SZ-1:0] match_mask;
    // always_comb begin
    //     idx_found = '0;
    //     matching_idx = '0;
    //     match_mask = '0;
    //     for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
    //         for (int unsigned j = 0, LSQ_IDX idx = 0; j < SQ_RET_BUF_SZ; j++) begin
    //             idx = (head+j) % SQ_RET_BUF_SZ;
    //             match_mask[i][idx] = 1;
    //             if (state[idx].d_vld && (state[idx].sq_idx == sq_in.forward_sq_idx[i])) begin
    //                 matching_idx[i] = idx;
    //                 idx_found[i] = 1;
    //                 break;
    //             end
    //         end

    //         if (!idx_found[i]) match_mask[i] = '1;
    //     end

    //     // for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
    //     //     if (idx_found[i]) begin
    //     //         for (int unsigned j = 0, LSQ_IDX idx = 0; j < SQ_RET_BUF_SZ; j++) begin
    //     //             idx = (head+j) % SQ_RET_BUF_SZ;
    //     //             match_mask[i][idx] = 1;
    //     //             if (idx == matching_idx[i]) break;
    //     //         end
    //     //     end
    //     //     else match_mask[i] = '1; //if idx isn't here, everything is old enough to take
    //     // end
    // end

    logic [LD_BAY_SZ-1:0] [3:0] [SQ_RET_BUF_SZ-1:0] byte_matches;
    logic [LD_BAY_SZ-1:0] [3:0] [SQ_RET_BUF_SZ-1:0] shifted_matches;
    logic [LD_BAY_SZ-1:0] [3:0] [SQ_RET_BUF_SZ-1:0] final_matches;
    genvar i,j,k,l;
    generate
        for (i = 0; i < LD_BAY_SZ; i++) begin : find_bay_matches

            assign matching_idx[i] = sq_in.forward_sq_idx[i] % SQ_RET_BUF_SZ;
            assign idx_found[i] = (state[matching_idx[i]].d_vld & (state[matching_idx[i]].sq_idx == sq_in.forward_sq_idx[i])) ? 1 : 0;

            for (l = 0; l < SQ_RET_BUF_SZ; l++) begin : find_match_mask
                assign match_mask[i][l] = ((matching_idx[i] < head) & ((l <= matching_idx[i]) || (l >= head))) || ((l >= head) && (l <= matching_idx[i])) ? 1 : 0;
            end

            for (j = 0; j < 4; j++) begin : find_byte_matches
                for (k = 0; k < SQ_RET_BUF_SZ; k++) begin : find_table_matches
                    assign byte_matches[i][j][k] = state[k].d_vld & (waddr(state[k].addr) == waddr(sq_in.forward_addr[i])) ? state[k].bytewise_addr_mask[j] & match_mask[i][k] : '0;
                end

                psel_gen #(
                .WIDTH  (SQ_RET_BUF_SZ),
                .REQS   (1)
                ) sel (
                    .req    (byte_matches[i][j]),
                    .gnt_bus(shifted_matches[i][j])
                );

                assign final_matches[i][j] = rotate_right(shifted_matches[i][j],matching_idx[i]);
                assign next_forward_ret_2_sq.forward_data[i].byte_level[j] = idx_found[i] ? state[encode_idx(final_matches[i][j])].data.byte_level[j] : '0;
                assign next_forward_ret_2_sq.forward_byte_en[i][j] = idx_found[i] ? state[encode_idx(rotate_right(shifted_matches[i][j],matching_idx[i]))].bytewise_addr_mask[j] : '0;//1;
                    
            end

            assign next_forward_ret_2_sq.forward_en[i] = (next_forward_ret_2_sq.forward_byte_en[i] != 0);
        end
    endgenerate

    // genvar a,b;
    // generate
    //     for (a = 0; a < LD_BAY_SZ; a++) begin : find_most_recent_match_1
    //         for (b = 0; b < 4; b++) begin : find_most_recent_match_2
    //             psel_gen #(
    //             .WIDTH  (SQ_RET_BUF_SZ),
    //             .REQS   (1)
    //             ) sel (
    //                 .req    (byte_matches[a][b]),
    //                 .gnt_bus(shifted_matches[a][b])
    //             );
    //         end
    //     end
    // endgenerate

    // always_comb begin
    //     for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
    //         for (int unsigned j = 0; j < 4; j++) begin
    //             final_matches[i][j] = rotate_right(shifted_matches[i][j],matching_idx[i]) & match_mask[i];
    //             // $display("FINAL_MASK[%0d][%0d], %b", i, j, final_matches[i][j]);
    //         end
    //     end
    // end

    // generate
    //     // next_forward_ret_2_sq = '0;
    //     for (i = 0; i < LD_BAY_SZ; i++) begin : assign_next_forward_1
    //         for (j = 0; j < 4; j++) begin : assign_next_forward_2
    //                 // assign idx = encode_idx(rotate_right(shifted_matches[i][j],matching_idx[i]));
    //                 assign next_forward_ret_2_sq.forward_data[i].byte_level[j] = idx_found[i] ? state[encode_idx(rotate_right(shifted_matches[i][j],matching_idx[i]))].data.byte_level[j] : '0;
    //                 assign next_forward_ret_2_sq.forward_byte_en[i][j] = idx_found[i] ? state[encode_idx(rotate_right(shifted_matches[i][j],matching_idx[i]))].bytewise_addr_mask[j] : '0;//1;
                    
    //         end
    //         assign next_forward_ret_2_sq.forward_en[i] = (next_forward_ret_2_sq.forward_byte_en[i] != 0);
    //         // $display("FORWARD_DATA[%0d]: %0d, en: %b, mask: %4b", i, next_forward_ret_2_sq.forward_data[i], next_forward_ret_2_sq.forward_en[i], next_forward_ret_2_sq.forward_byte_en[i]);
    //     end
    // endgenerate
    


    always_ff @(posedge clock) begin
        if (reset) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            state   <= '0;
            sq_frwd_out <= '0;
        end else begin
            used    <= used + sq_in.ret_cnt - ret_success;
            head    <= (head + ret_success) % SQ_RET_BUF_SZ;
            tail    <= (tail + sq_in.ret_cnt) % SQ_RET_BUF_SZ;

            sq_frwd_out <= next_forward_ret_2_sq;

            // handle sq to ret buffer (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= sq_in.ret_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= sq_in.ret_st[i];
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
        sq_in,
        mem2proc_transaction_tag,

        sq_out,
        sq_frwd_out,
        mem_out
    };
    `endif

    function automatic logic [SQ_RET_BUF_SZ-1:0] rotate_left;
    input logic [SQ_RET_BUF_SZ-1:0] data;
    input int unsigned shift;
    begin
        rotate_left = (data << shift) | (data >> shift);
    end
    endfunction

    function automatic logic [SQ_RET_BUF_SZ-1:0] rotate_right;
        input logic [SQ_RET_BUF_SZ-1:0] data;
        input int unsigned shift;
        begin
            rotate_right = (data >> shift) | (data << shift);
        end
    endfunction

    function automatic LSQ_IDX encode_idx;
        input logic [SQ_RET_BUF_SZ-1:0] data;
        begin
            case (data)
                16'b0000000000000001 : encode_idx = 5'd0;
                16'b0000000000000010 : encode_idx = 5'd1;
                16'b0000000000000100 : encode_idx = 5'd2;
                16'b0000000000001000 : encode_idx = 5'd3;
                16'b0000000000010000 : encode_idx = 5'd4;
                16'b0000000000100000 : encode_idx = 5'd5;
                16'b0000000001000000 : encode_idx = 5'd6;
                16'b0000000010000000 : encode_idx = 5'd7;
                16'b0000000100000000 : encode_idx = 5'd8;
                16'b0000001000000000 : encode_idx = 5'd9;
                16'b0000010000000000 : encode_idx = 5'd10;
                16'b0000100000000000 : encode_idx = 5'd11;
                16'b0001000000000000 : encode_idx = 5'd12;
                16'b0010000000000000 : encode_idx = 5'd13;
                16'b0100000000000000 : encode_idx = 5'd14;
                16'b1000000000000000 : encode_idx = 5'd15;
                default: encode_idx = 5'd0;
            endcase
        end
    endfunction

endmodule




//NOTICE: The below is an attempt at an optimized forwarding method. It ran aground due to incompatibility with circular buffers. Leaving it here at the bottom of the 
//file in case we ever want to come back to it
    // logic [LD_BAY_SZ-1:0] [SQ_RET_BUF_SZ-1:0] [3:0] byte_matches;
    // always_comb begin
    //     byte_matches = 0;
    //     next_forward_ret_2_sq = '0;

    //     //find all matches in parallel
    //     for (int unsigned i = 0; i < LD_BAY_SZ; ++i) begin
    //         for (int unsigned j = 0, int unsigned idx = 0; j < SQ_RET_BUF_SZ; ++j) begin
    //             idx = (head + j) % SQ_RET_BUF_SZ;

    //             if (state[idx].d_vld && (waddr(state[idx].addr) == waddr(sq_in.forward_addr[i]))) begin
    //                 byte_matches[i][j] = state[idx].bytewise_addr_mask;
    //                 // $display("FOUND_MATCH[%0d]: %0d, %4b", idx, state[idx].data, byte_matches[i][j]);
    //             end
    //         end
    //     end

    //     //apply the matches bottom-up to catch the most recent matches first
    //     for (int unsigned i = 0; i < LD_BAY_SZ; ++i) begin
    //         if (!sq_in.forward_req_en[i]) continue;

    //         for (int unsigned j = 0, logic [$clog2(SQ_RET_BUF_SZ)-1:0] idx = 0; j < used; ++j) begin
    //             idx = tail - j - 1;

    //             if (state[idx].sq_idx == sq_in.forward_sq_idx[i]) begin
    //                 next_forward_ret_2_sq.sq_idx_found[i] = 1;
    //                 next_forward_ret_2_sq.forward_data[i] = '0;
    //                 next_forward_ret_2_sq.forward_byte_en[i] = '0;
    //                 // $display("EXACT");
    //             end

    //             next_forward_ret_2_sq.forward_data[i].byte_level[0] = byte_matches[i][idx][0] ? state[idx].data.byte_level[0] : next_forward_ret_2_sq.forward_data[i].byte_level[0];
    //             next_forward_ret_2_sq.forward_data[i].byte_level[1] = byte_matches[i][idx][1] ? state[idx].data.byte_level[1] : next_forward_ret_2_sq.forward_data[i].byte_level[1];
    //             next_forward_ret_2_sq.forward_data[i].byte_level[2] = byte_matches[i][idx][2] ? state[idx].data.byte_level[2] : next_forward_ret_2_sq.forward_data[i].byte_level[2];
    //             next_forward_ret_2_sq.forward_data[i].byte_level[3] = byte_matches[i][idx][3] ? state[idx].data.byte_level[3] : next_forward_ret_2_sq.forward_data[i].byte_level[3];


    //             next_forward_ret_2_sq.forward_byte_en[i] |= byte_matches[i][idx];

    //             // $display("FINAL_DATA: %0d, %4b, %0d, %0d", next_forward_ret_2_sq.forward_data[i], byte_matches[i][idx], state[idx].data, idx);
    //             // $display("EXACT? %b, %0d, %0d", next_forward_ret_2_sq.sq_idx_found[i], state[idx].sq_idx,sq_in.forward_sq_idx[i]);

    //             if (next_forward_ret_2_sq.forward_byte_en[i] == 4'b1111) break;

    //         end

    //         next_forward_ret_2_sq.forward_en[i] = (next_forward_ret_2_sq.forward_byte_en[i] != 0);
    //     end
    // end