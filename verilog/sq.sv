`include "sys_defs.svh"


/* Get word address; restricting to only actually used 16 LSB. */
function automatic WADDR get_waddr(input ADDR addr);
    return addr[15:2];
endfunction

/* In-word offset */
function automatic logic[1:0] iw_off(input ADDR addr);
    return addr[1:0];
endfunction

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

    /* Q: Why did I rename? We are already in the sq module; we HAVE context.
    There is no need to tattoo sq on every siganl. It is NOISE. */
    input dispatch2sq   dis_in,
    input execute2sq    ex_in,
    input executeLD2sq  ld_in,
    input retire2sq     retire_in,
    input MEM_TAG       mem2proc_transaction_tag,

    output sq2dispatch  dis_out,
    output sq2execute   ex_out,
    output sq2rob       rob_out,
    output sq2retire    retire_out,
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

    LSQ_IDX [N-1:0] next_ids;
    execute2sq next_complete;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            next_ids[i] = (tail_dbl + i) % LSQ_SZ_DBL;

        // handle dispatch (outs)
        dis_out = '{
            sq_rdy_scnt         : free_scnt,
            last_used_sq_idx    : last_used_sq_idx,
            next_ids            : next_ids,
            no_store_yet        : no_store_yet
        };

        //handle sq to ROB for retirement
        rob_out = '0;
        rob_out.complete_en = next_complete.st_ex_en;
        for (int i = 0; i < NUM_FU_STORE; i++) begin
            if (i >= next_complete.st_ex_en)
                continue;

            rob_out.complete_rob_idxs[i] = state[next_complete.st_sq_idx[i]].rob_idx;
        end
        
        // retire
        retire_out.sq_ret_complete = (ret_2_sq.used_scnt == 0) && (used_scnt == 0);
    end


    SQ_ENTRY [`N-1:0] tmp_ret_st;
    always_comb begin
        foreach (r_idxs[i])
            tmp_ret_st[i] = state[r_idxs[i]];

        sq_2_ret = '{
            //handle retirement write to mem
            ret_cnt    : retire_in.r_en,
            ret_st     : tmp_ret_st,

            //handle data forwarding
            forward_req_en      : ld_in.forward_req_en,
            forward_sq_idx      : ld_in.forward_sq_idx,
            forward_addr        : ld_in.forward_addr,
            forward_mem_size    : ld_in.forward_mem_size
        };
    end

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


    logic       [LD_BAY_SZ-1:0]      forward_en;
    DATA_BLOCK  [LD_BAY_SZ-1:0]      forward_data;
    MEM_SIZE    [LD_BAY_SZ-1:0]      forward_mem_size;
    logic       [LD_BAY_SZ-1:0][3:0] forward_byte_en;
    // per bay tmps
    WADDR start;
    logic [LSQ_SZ-1:0]      used_range;
    logic [LSQ_SZ-1:0]      addr_match;
    logic [LSQ_SZ-1:0][3:0] byte_match;
    logic [LSQ_SZ-1:0][3:0] byte_m1hot;

    logic [LD_BAY_SZ-1:0][LSQ_SZ-1:0]      tmp_addr_match;
    logic [LD_BAY_SZ-1:0][LSQ_SZ-1:0][3:0] tmp_byte_match;
    logic [LD_BAY_SZ-1:0][LSQ_SZ-1:0][3:0] tmp_byte_m1hot;
    always_comb begin
        forward_en       = '0;
        forward_data     = '0;
        forward_mem_size = '0;
        forward_byte_en  = '0;

        // FIXME: maybe have a valid bit per entry instead of recomputing this every cycle?
        used_range = '0;
        for (int off = 0, int j = head;
            off < used; 
            ++off, j = (j + 1) % LSQ_SZ) begin
            used_range[j] = 1;
        end

        for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
            start = get_waddr(ld_in.forward_addr[i]);
            addr_match = '0;
            byte_match = '0;
            byte_m1hot = '0;

            if (!ld_in.forward_req_en[i])
                continue;

            foreach (addr_match[j]) begin
                addr_match[j] = used_range[j]
                    && state[j].d_vld                                   // got data?
                    && (get_waddr(state[j].addr) == start)              // match word-aligned addr? 
                    && (state[j].sq_idx < ld_in.forward_sq_idx[i]);   // is older?
            end

            foreach (byte_match[j, b]) begin
                byte_match[j][b] = addr_match[j]
                    && state[j].bytewise_addr_mask[b];
            end

            for (int b = 0; b < 4; ++b) begin
                for (int off = 0, int unsigned j = tail;
                    off < used;
                    ++off, j = j ? (j - 1) : LSQ_SZ - 1) begin
                    if (!byte_match[j][b])
                        continue;

                    byte_m1hot[j][b] = 1;
                    break;
                end
            end

            foreach (byte_match[j])
                forward_byte_en[i] |= byte_match[j];
            forward_en[i] = forward_byte_en[i] != 0;

            foreach (byte_m1hot[j, b]) begin
                if (!byte_m1hot[j][b])
                    continue;
                forward_data[i].byte_level[b] |= state[j].data.byte_level[b];
            end

            tmp_addr_match[i] = addr_match;
            tmp_byte_match[i] = byte_match;
            tmp_byte_m1hot[i] = byte_m1hot;
        end
    end

    `ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("=== Forwarding Info ===");
            $display("-- used_range:     %b, head: %d, used: %d",   used_range, head, used);
            $display("-- addr_match:     %b",   tmp_addr_match);
            $display("-- byte_match:     %b",   tmp_byte_match);
            $display("-- byte_m1hot:     %b",   tmp_byte_m1hot);
            for (int i = 0; i < LD_BAY_SZ; i++) begin
                $display("Bay %0d:", i);
                $display("  req_en     = %0b", ld_in.forward_req_en[i]);
                $display("  sq_idx     = %0d", ld_in.forward_sq_idx[i]);
                $display("  addr       = 0x%08x", ld_in.forward_addr[i]);
                $display("  mem_size   = %0d", ld_in.forward_mem_size[i]); // BYTE=0, HALF=1, WORD=2 (assuming enum encoding)
                $display("  forward_en       = %0b", forward_en[i]);
                $display("  forward_data     = 0x%8h", forward_data[i]);
                $display("  forward_mem_size = %0d", forward_mem_size[i]);
                $display("  forward_byte_en  = %4b", forward_byte_en[i]);
                $display("  ret_2_sq.sq_found         = %0b",   forward_ret_2_sq.sq_idx_found[i]);
                $display("  ret_2_sq.forward_en       = %0b",   forward_ret_2_sq.forward_en[i]);
                $display("  ret_2_sq.forward_data     = 0x%8h", forward_ret_2_sq.forward_data[i]);
                $display("  ret_2_sq.forward_mem_size = %0d",   forward_ret_2_sq.forward_mem_size[i]);
                $display("  ret_2_sq.forward_byte_en  = %4b",   forward_ret_2_sq.forward_byte_en[i]);
            end
            $display("========================");
        end
    end
    `endif

    always_comb begin
        ex_out = '0;
        for (int unsigned i = 0, int wr_off = 0; i < LD_BAY_SZ; i++) begin
            /* BUG: test5, 6. sq_idx_found not being set properly */
            if (forward_ret_2_sq.sq_idx_found[i]) begin
                ex_out.forward_en[i]                |= forward_ret_2_sq.forward_en[i];
                ex_out.forward_data[i].word_level   |= forward_ret_2_sq.forward_data[i];
                ex_out.forward_byte_en[i]           |= forward_ret_2_sq.forward_byte_en[i];
            end else begin
                ex_out.forward_en[i]                |= forward_en[i];
                ex_out.forward_data[i]              |= forward_data[i];
                ex_out.forward_byte_en[i]           |= forward_byte_en[i];
            end

            wr_off = 8 * iw_off(ld_in.forward_addr[i]);
            ex_out.forward_data[i]       = ex_out.forward_data[i] >> wr_off;
            ex_out.forward_byte_en[i]    = ex_out.forward_byte_en[i] >> wr_off;

            //ensure don't accidentally give more data than it wants
            case (ld_in.forward_mem_size[i])
                BYTE: begin
                    ex_out.forward_data[i]      &= 8'hFF;
                    ex_out.forward_byte_en[i]   &= 1'b1;
                end
                HALF: begin
                    ex_out.forward_data[i]      &= 16'hFFFF;
                    ex_out.forward_byte_en[i]   &= 2'b11;
                end
            endcase
        end
    end

    logic [`NUM_FU_STORE-1:0] [3:0] bytewise_addr_mask;
    logic [`NUM_FU_STORE-1:0] [1:0] modulo4;
    always_comb begin
        bytewise_addr_mask = '0;
        modulo4 = '0;

        for (int i = 0; i < `NUM_FU_STORE; i++) begin
            modulo4[i] = iw_off(ex_in.st_addr[i]);

            case (ex_in.st_mem_size[i])
                BYTE:   bytewise_addr_mask[i][modulo4[i]]       = 1;
                HALF:   bytewise_addr_mask[i][modulo4[i]+:1]    = '1;
                default:bytewise_addr_mask[i]                   = '1;
            endcase
        end

        
    end

    logic [`NUM_FU_STORE-1:0] [4:0] updateOffset;
    always_comb begin
        updateOffset = '0;
        for (int i = 0; i < `NUM_FU_STORE; i++)
            updateOffset[i] = 8 * iw_off(ex_in.st_addr[i]);
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
            used    <= used + dis_in.sq_d_en_cnt - retire_in.r_en;
            free    <= free - dis_in.sq_d_en_cnt + retire_in.r_en;
            rsvd    <= rsvd - dis_in.sq_d_en_cnt + dis_in.rename_en_cnt;

            head    <= (head + retire_in.r_en) % LSQ_SZ;
            tail    <= (tail + dis_in.sq_d_en_cnt) % LSQ_SZ;
            tail_dbl <= (tail_dbl + dis_in.sq_d_en_cnt) % LSQ_SZ_DBL;
            last_used_sq_idx <= dis_in.sq_d_en_cnt > 0 ? (last_used_sq_idx + dis_in.sq_d_en_cnt) % LSQ_SZ_DBL : last_used_sq_idx;
            no_store_yet <= (dis_in.sq_d_en_cnt > 0) | no_store_yet;

            next_complete <= ex_in;

            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
                cur_idx = ex_in.st_sq_idx[i];
                
                if (ex_in.st_ex_en[i]) begin
                    state[cur_idx].addr                 <= ex_in.st_addr[i];
                    state[cur_idx].bytewise_addr_mask   <= bytewise_addr_mask[i];
                    state[cur_idx].data                 <= (ex_in.st_data[i] << updateOffset[i]);
                    state[cur_idx].mem_size             <= ex_in.st_mem_size[i];
                    state[cur_idx].d_vld                <= '1;
                end

            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= dis_in.sq_d_en_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    sq_idx              : next_ids[i],
                    rob_idx             : dis_in.rob_idx[i],
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
        dis_in,
        ex_in,
        retire_in,
        mem2proc_transaction_tag,

        dis_out,
        ex_out,
        // sq2rs sq_2_rs,
        retire_out,
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
    logic [4:0] writeOffset;
    always_comb begin
        ret_2_sq = '0;
        writeOffset = '0;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;

        // handle ret_2_sq
        ret_2_sq.free_scnt  = free_scnt;
        ret_2_sq.used_scnt  = used_scnt;

        //handle retirement write to mem
        ret_2_mem = '0;
        if (head != tail) begin
            writeOffset = 8 * iw_off(state[head].addr);

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
            if (!sq_2_ret.forward_req_en[i])
                continue;

            start = get_waddr(sq_2_ret.forward_addr[i]);
            for (int unsigned j = 0, int unsigned idx = 0; j < used; ++j) begin
                idx = (head+j) % LSQ_SZ;

                // FIXME: This used to be ==. Is this <= correct?
                if (state[idx].sq_idx <= sq_2_ret.forward_sq_idx[i])
                    forward_ret_2_sq.sq_idx_found[i] = '1;

                if (state[idx].d_vld && (get_waddr(state[idx].addr) == start)) begin
                    forward_ret_2_sq.forward_data[i][7:0]   = state[idx].bytewise_addr_mask[0] ? state[idx].data[7:0]      : forward_ret_2_sq.forward_data[i][7:0];
                    forward_ret_2_sq.forward_data[i][15:8]  = state[idx].bytewise_addr_mask[1] ? state[idx].data[15:8]     : forward_ret_2_sq.forward_data[i][15:8];
                    forward_ret_2_sq.forward_data[i][23:16] = state[idx].bytewise_addr_mask[2] ? state[idx].data[23:16]    : forward_ret_2_sq.forward_data[i][23:16];
                    forward_ret_2_sq.forward_data[i][31:24] = state[idx].bytewise_addr_mask[3] ? state[idx].data[31:24]    : forward_ret_2_sq.forward_data[i][31:24];


                    forward_ret_2_sq.forward_byte_en[i] |= state[idx].bytewise_addr_mask;
                end

                if (state[idx].sq_idx == sq_2_ret.forward_sq_idx[i])
                    break;
            end

            forward_ret_2_sq.forward_en[i] = forward_ret_2_sq.forward_byte_en[i] != 0;
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


