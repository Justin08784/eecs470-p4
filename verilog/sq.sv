`include "sys_defs.svh"
`include "dcache_block_direct.svh"


module sq #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
    // LSQ_SZ=`LSQ_SZ,
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
    input dcache2sq     dcache_in,

    output sq2dispatch  dispatch_out,
    output sq2execute   execute_out,
    output sq2rob       rob_out,
    output sq2retire    retire_out,
    output sq2dcache    dcache_out
);

    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_ST_PORTS = NUM_FU_STORE; // ex-2-sq ports
    localparam NUM_LD_PORTS = NUM_FU_LOAD;

    logic [$clog2(LSQ_SZ)-1:0]      head;
    logic [$clog2(LSQ_SZ)-1:0]      ret_head;
    logic [$clog2(LSQ_SZ)-1:0]      tail;
    // logic [$clog2(LSQ_SZ)-1:0]      tail_dbl;
    LSQ_IDX                         last_used_sq_idx;
    logic                           no_store_yet;

    SQ_ENTRY [LSQ_SZ-1:0]           state;
    logic [$clog2(LSQ_SZ):0]        used, free, ret_buf_used, ret_buf_free;
    logic [$clog2(2*`N):0]          rsvd; // sz(rename_buf) = 2*`N

    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;
    assign free_scnt    = `MIN(free - rsvd, NUM_DPORTS);
    assign used_scnt    = `MIN(used, NUM_RPORTS);

    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] m_idxs;
    logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;
    LSQ_IDX [N-1:0] next_ids;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            next_ids[i] = (tail + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            m_idxs[i] = (ret_head + i) % LSQ_SZ;
    end


    /* >> ======== SECTION: Retirement ======== >> */
    execute2sq      next_complete;
    logic [$clog2(N):0] ret_success;

    always_comb begin
        //handle retirement write to mem
        dcache_out = '0;

        if (ret_head != head) begin
            dcache_out = '{
                vld     : 1,
                addr    : state[ret_head].addr,
                size    : state[ret_head].mem_size,
                dat     : (state[ret_head].data >> (8 * iw_off(state[ret_head].addr)))
            };
        end
        ret_success = dcache_in.status == ST_SUCC;
    end
    

    always_comb begin
        rob_out = '0;
        //handle sq to ROB for retirement
        rob_out.complete_en = next_complete.st_ex_en;
        for (int i = 0; i < NUM_FU_STORE; i++) begin
            if (i >= next_complete.st_ex_en)
                continue;

            rob_out.complete_rob_idxs[i] = state[next_complete.st_sq_idx[i] % LSQ_SZ].rob_idx;
        end
        retire_out.sq_ret_complete = ret_head == head;
        retire_out.sq_ret_en = `MIN(N,ret_buf_free);

    end

    /* >> ======== SECTION: Execute ======== >> */
    sq2execute next_sq_2_exec;


    logic [LD_BAY_SZ-1:0] idx_found;
    LSQ_IDX [LD_BAY_SZ-1:0] matching_idx;
    logic [LD_BAY_SZ-1:0] [LSQ_SZ-1:0] match_mask;

    logic [LD_BAY_SZ-1:0] [3:0] [LSQ_SZ-1:0] byte_matches;
    logic [LD_BAY_SZ-1:0] [3:0] [LSQ_SZ-1:0] shifted_left_matches;
    logic [LD_BAY_SZ-1:0] [3:0] [LSQ_SZ-1:0] shifted_right_matches;
    logic [LD_BAY_SZ-1:0] [3:0] [LSQ_SZ-1:0] final_matches;

    logic [LD_BAY_SZ-1:0] [3:0] word_off;

    genvar bay_m,byte_m,table_m,mask_m;
    generate
        for (bay_m = 0; bay_m < LD_BAY_SZ; bay_m++) begin : find_bay_matches

            assign matching_idx[bay_m] = ex_frwd_in.forward_sq_idx[bay_m];
            assign idx_found[bay_m] = state[matching_idx[bay_m]].in_range;

            for (mask_m = 0; mask_m < LSQ_SZ; mask_m++) begin : find_match_mask

                // if (!state[mask_m].in_range) assign match_mask[bay_m][mask_m] = 0;
                // else if (tail > head) assign match_mask[bay_m][mask_m] = (mask_m >= ret_head) && (mask_m <= matching_idx[bay_m]);
                // else if (matching_idx[bay_m] < tail) assign match_mask[bay_m][mask_m] = (mask_m <= matching_idx[bay_m]) || (mask_m >= ret_head);
                // else assign match_mask[bay_m][mask_m] = (mask_m >= ret_head) && (mask_m <= matching_idx[bay_m]);

                assign match_mask[bay_m][mask_m] = !state[mask_m].in_range ?
                    0 :
                    tail > head ?
                        (mask_m >= ret_head) && (mask_m <= matching_idx[bay_m]) :
                        matching_idx[bay_m] < tail ?
                            (mask_m <= matching_idx[bay_m]) || (mask_m >= ret_head) :
                            (mask_m >= ret_head) && (mask_m <= matching_idx[bay_m]);
            end
            

            for (byte_m = 0; byte_m < 4; byte_m++) begin : find_byte_matches
                for (table_m = 0; table_m < LSQ_SZ; table_m++) begin : find_table_matches
                    assign byte_matches[bay_m][byte_m][table_m] = state[table_m].d_vld && (waddr(state[table_m].addr) == waddr(ex_frwd_in.forward_addr[bay_m])) ? 
                        state[table_m].bytewise_addr_mask[byte_m] & match_mask[bay_m][table_m] : '0;
                end

                assign shifted_left_matches[bay_m][byte_m] = rotate_left(byte_matches[bay_m][byte_m],(LSQ_SZ-1)-matching_idx[bay_m]);

                psel_gen #(
                .WIDTH  (LSQ_SZ),
                .REQS   (1)
                ) sel (
                    .req    (shifted_left_matches[bay_m][byte_m]),
                    .gnt    (shifted_right_matches[bay_m][byte_m])
                );
                assign final_matches[bay_m][byte_m] = rotate_right(shifted_right_matches[bay_m][byte_m],(LSQ_SZ-1)-matching_idx[bay_m]);
                assign next_sq_2_exec.forward_data[bay_m].byte_level[byte_m] = final_matches[bay_m][byte_m] != 0 ? state[encode_idx(final_matches[bay_m][byte_m])].data.byte_level[byte_m] : '0;
                assign next_sq_2_exec.forward_byte_en[bay_m][byte_m] = final_matches[bay_m][byte_m] != 0 ? state[encode_idx(final_matches[bay_m][byte_m])].bytewise_addr_mask[byte_m] : '0;//1;
                    
            end

            assign next_sq_2_exec.forward_en[bay_m] = (next_sq_2_exec.forward_byte_en[bay_m] != 0);

            assign execute_out.forward_en[bay_m] = idx_found[bay_m] && ex_frwd_in.forward_req_en[bay_m] && next_sq_2_exec.forward_en[bay_m];

            assign word_off[bay_m] = iw_off(ex_frwd_in.forward_addr[bay_m]);
            
            assign execute_out.forward_data[bay_m] = idx_found[bay_m] && ex_frwd_in.forward_req_en[bay_m] ? 
                shift_data(next_sq_2_exec.forward_data[bay_m], word_off[bay_m], ex_frwd_in.forward_mem_size[bay_m]) : '0; 
            
            assign execute_out.forward_byte_en[bay_m] = idx_found[bay_m] && ex_frwd_in.forward_req_en[bay_m] ? 
                shift_byte_mask(next_sq_2_exec.forward_byte_en[bay_m], word_off[bay_m], ex_frwd_in.forward_mem_size[bay_m]) : '0;

            assign execute_out.forward_mem_size[bay_m] = idx_found[bay_m] && ex_frwd_in.forward_req_en[bay_m] ? 
                ex_frwd_in.forward_mem_size[bay_m] : 0;

        end
    endgenerate


    logic [`NUM_FU_STORE-1:0] [3:0] bytewise_addr_mask;
    always_comb begin
        bytewise_addr_mask = '0;

        for (int i = 0, int unsigned word_off = 0; i < `NUM_FU_STORE; i++) begin
            word_off = iw_off(execute_in.st_addr[i]);

            case (execute_in.st_mem_size[i])
                BYTE:   bytewise_addr_mask[i][word_off]     = 1;
                HALF:   bytewise_addr_mask[i][word_off+:2]  = '1;
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

    logic has_retired_something;

    always_ff @(posedge clock) begin

        // $display("CUR_STATE: flush: %byte_m, ret_head: %0d, ret_used: %0d, last_used_sq_idx: %0d, has_retired_something: %byte_m", flush, ret_head, ret_buf_used, last_used_sq_idx, has_retired_something);
        
        if (reset) begin
            used    <= 0;
            free    <= LSQ_SZ;
            ret_buf_used <= 0;
            ret_buf_free <= 4;
            rsvd    <= 0;

            head    <= 0;
            ret_head<= 0;
            tail    <= 0;
            // tail_dbl <= 0;
            state   <= '0;
            last_used_sq_idx <= LSQ_SZ; //outside of SQ range so that if bay_m load occurs before the first store we don't flag it falsely
            next_complete <= '0;
            no_store_yet <= '1;
            has_retired_something <= 0;
        end 
        else if (flush) begin
            used <= ret_buf_used;
            free <= LSQ_SZ - ret_buf_used;
            ret_buf_used <= ret_buf_used;
            ret_buf_free <= ret_buf_free;
            rsvd <= 0;

            ret_head <= ret_head;
            head <= (ret_head + ret_buf_used) % LSQ_SZ;
            tail <= (ret_head + ret_buf_used) % LSQ_SZ;
            // tail_dbl <= (ret_head + ret_buf_used) % LSQ_SZ;
            if (has_retired_something) begin
                last_used_sq_idx <= ((ret_head == 0) && (ret_buf_used == 0)) ? (LSQ_SZ - 1) : (ret_head + ret_buf_used - 1) % LSQ_SZ;
            end
            else last_used_sq_idx <= LSQ_SZ;
            // last_used_sq_idx <= has_retired_something ? (ret_head + ret_buf_used - 1) % LSQ_SZ : LSQ_SZ;
            next_complete <= '0;
            no_store_yet <= ~has_retired_something;
            has_retired_something <= has_retired_something;

            for (int unsigned i = 0, int unsigned idx = 0; i < LSQ_SZ; i++) begin
                idx = (ret_head + i) % LSQ_SZ;

                if (i < ret_buf_used) state[idx] <= state[idx];
                else state[idx] <= '0;
            end

        end 
        else begin
            used    <= used + dispatch_in.sq_d_en_cnt - ret_success;//retire_in.r_en;
            free    <= free - dispatch_in.sq_d_en_cnt + ret_success;//retire_in.r_en;
            ret_buf_used <= ret_buf_used - ret_success + retire_in.r_en;
            ret_buf_free <= ret_buf_free + ret_success - retire_in.r_en;
            rsvd    <= rsvd - dispatch_in.sq_d_en_cnt + dispatch_in.rename_en_cnt;

            head    <= (head + retire_in.r_en) % LSQ_SZ;
            ret_head<= (ret_head + ret_success) % LSQ_SZ;
            tail    <= (tail + dispatch_in.sq_d_en_cnt) % LSQ_SZ;
            // tail_dbl <= (tail_dbl + dispatch_in.sq_d_en_cnt) % LSQ_SZ;
            last_used_sq_idx <= (dispatch_in.sq_d_en_cnt > 0) ? (last_used_sq_idx + dispatch_in.sq_d_en_cnt) % LSQ_SZ : last_used_sq_idx;
            no_store_yet <= (dispatch_in.sq_d_en_cnt > 0) ? 0 : no_store_yet;
            has_retired_something <= has_retired_something | (retire_in.r_en > 0);

            // $display("LAST_USED: %0d, %byte_m", last_used_sq_idx, no_store_yet);

            next_complete <= execute_in;
            // uncombined_forward_data <= next_sq_2_exec;

            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
                cur_idx = execute_in.st_sq_idx[i] % LSQ_SZ;
                
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
                    in_range            : '1,
                    mem_size            : '0
                };
            end

            //handle mem success updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_RPORTS; ++i) begin
                if (i >= ret_success) continue;

                cur_idx = m_idxs[i];
                state[cur_idx].d_vld <= 0;
                state[cur_idx].in_range <= 0;
            end

        end
    end


    `ifdef DEBUG
    assign dbg = '{
        // internal state
        state,
        head,
        ret_head,
        tail,
        used,
        free,
        rsvd,
        // I/O
        dispatch_in,
        execute_in,
        retire_in,

        dispatch_out,
        execute_out,
        // sq2rs sq_2_rs,
        retire_out,
        '0

        // dbg_retbuf
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

    function automatic DATA_BLOCK shift_data;
        input DATA_BLOCK data_in;
        input logic [1:0] word_off;
        input MEM_SIZE mem_size;
        begin
            case (mem_size)
                BYTE: begin
                    shift_data      = (data_in >> (8 * word_off)) & 32'h000000FF;
                end
                HALF: begin
                    shift_data       = (data_in >> (8 * word_off)) & 32'h0000FFFF;
                end
                default: begin
                    shift_data       = (data_in >> (8 * word_off));//&= 32'hFFFFFFFF;
                end
            endcase
        end
    endfunction

    function automatic logic [3:0] shift_byte_mask;
        input logic [3:0] mask;
        input logic [1:0] word_off;
        input MEM_SIZE mem_size;
        begin
            case (mem_size)
                BYTE: begin
                    shift_byte_mask    = (mask >> word_off) & 4'b0001;
                end
                HALF: begin
                    shift_byte_mask    = (mask >> word_off) & 4'b0011;
                end
                default: begin
                    shift_byte_mask    = (mask >> word_off);//&= 4'b1111;
                end
            endcase
        end
    endfunction


endmodule

