`include "sys_defs.svh"


module lq #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
    LSQ_SZ_DBL=`LSQ_SZ_DBL,
    NUM_FU_STORE=`NUM_FU_STORE,
    NUM_FU_LOAD=`NUM_FU_LOAD
) (
    `ifdef DEBUG
    output DBG_lq dbg,
    `endif 

    input clock,
    input reset,
    input flush,

    input dispatch2lq dis_2_lq,
    input execute2lq exec_2_lq,
    input retire2lq retire_2_lq,

    output lq2dispatch lq_2_dis,
    output lq2rob lq_2_rob,
    output lq2retire retire_out
);

    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_ST_PORTS = NUM_FU_STORE; // ex-2-sq ports
    localparam NUM_LD_PORTS = NUM_FU_LOAD;
    logic [$clog2(NUM_DPORTS):0]    free_scnt;
    logic [$clog2(NUM_RPORTS):0]    used_scnt;

    logic [$clog2(LSQ_SZ)-1:0]  head;
    logic [$clog2(LSQ_SZ)-1:0]  tail;

    LQ_ENTRY [LSQ_SZ-1:0]       state;
    logic [$clog2(LSQ_SZ):0]    used, free;
    logic [$clog2(2*`N):0]      rsvd; // sz(rename_buf) = 2*`N

    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;

    assign free_scnt            = `MIN(free - rsvd, NUM_DPORTS);
    assign used_scnt            = `MIN(used, NUM_RPORTS);


    LSQ_IDX head_plus_one;
    always_comb begin
        lq_2_rob = '0;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;

        // handle dispatch (outs)
        lq_2_dis <= '{
            lq_rdy_scnt : free_scnt,
            lq_tail     : tail
        };

        //handle lsq to ROB for retirement
        head_plus_one = (head + 1) % LSQ_SZ;
        if (state[head].d_vld && state[head_plus_one].d_vld)    lq_2_rob.ret_rdy = 2;
        else if (state[head].d_vld)                             lq_2_rob.ret_rdy = 1;
        else                                                    lq_2_rob.ret_rdy = 0;      

        //handle checking if LQ got ahead of SQ and needs to flag it in ROB
        for (int i = 0; i < NUM_FU_STORE; i++) begin
            if (!exec_2_lq.st_en[i]) continue;

            for (int j = 0, int idx = 0; j < used; j++) begin
                idx = (head + j) % LSQ_SZ;
                if (state[idx].sq_idx == exec_2_lq.st_sq_idx[i]) begin
                    lq_2_rob.err_en[i] = '1;
                    lq_2_rob.rob_idx[i] = state[idx].rob_idx;
                end
            end
        end

        //handle telling fetch the top 2 PC's
        retire_out.PC[0] = state[head].inst_pc;
        retire_out.PC[1] = state[head_plus_one].inst_pc;
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            free    <= LSQ_SZ;
            rsvd    <= 0;

            head    <= 0;
            tail    <= 0;
            state   <= '0;
        end else begin
            used    <= used + dis_2_lq.lq_d_en_cnt - retire_2_lq.r_en;
            free    <= free - dis_2_lq.lq_d_en_cnt + retire_2_lq.r_en;
            rsvd    <= rsvd + dis_2_lq.rename_en_cnt - dis_2_lq.lq_d_en_cnt;

            head    <= (head + retire_2_lq.r_en) % LSQ_SZ;
            tail    <= (tail + dis_2_lq.lq_d_en_cnt) % LSQ_SZ;
            
            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
                cur_idx = exec_2_lq.ld_lq_idx[i];

                if (exec_2_lq.ld_ex_en[i]) begin
                    state[cur_idx].addr <= exec_2_lq.ld_addr[i];
                    state[cur_idx].mem_size <= exec_2_lq.ld_mem_size[i];
                    state[cur_idx].d_vld <= '1;
                end

            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= dis_2_lq.lq_d_en_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    lq_idx     : d_idxs[i],
                    sq_idx : dis_2_lq.sq_idx[i],
                    rob_idx : dis_2_lq.rob_idx[i],
                    addr     : '0,
                    d_vld     : '0,
                    mem_size : '0,
                    inst_pc : dis_2_lq.inst_pc[i]
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
        dis_2_lq,
        exec_2_lq,
        retire_2_lq,

        lq_2_dis,
        lq_2_rob
    };
    `endif 


endmodule