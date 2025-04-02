`include "sys_defs.svh"


module lq #(parameter 
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

    input dispatch2lq dis_2_lq,
    input execute2lq exec_2_lq,
    input rob2lq rob_2_lq,
    // input MEM_TAG mem2proc_transaction_tag,

    output lq2dispatch lq_2_dis,
    // output lq2execute lq_2_exec,
    // output lq2rs lq_2_rs,
    output lq2rob lq_2_rob
    // output stRET2mem ret_2_mem
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

    LQ_ENTRY [LSQ_SZ-1:0]       state;
    logic [$clog2(LSQ_SZ):0]    used, free;

    logic [NUM_RPORTS-1:0][$clog2(LSQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(LSQ_SZ)-1:0] d_idxs;

    `ifdef DEBUG
    assign state_dbg            = state;
    `endif 
    assign free                 = LSQ_SZ - used;
    assign free_scnt            = `MIN(free, NUM_DPORTS);
    assign used_scnt            = `MIN(used, NUM_RPORTS);


    LSQ_IDX head_plus_one;
    always_comb begin

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;

        // handle dispatch (outs)
        lq_2_dis <= '{
            lq_rdy_scnt : `MIN(free, NUM_DPORTS),
            lq_tail     : tail_dbl
        };

        //handle LSQ CDB to RS
        // lsq_2_rs <= '{
        //     en : exec_2_lq.st_ex_en,
        //     sq_idx_cdb     : exec_2_lq.st_sq_idx
        // };

        //handle lsq to ROB for retirement
        head_plus_one = (head + 1) % LSQ_SZ;
        if (state[head].d_vld && state[head_plus_one].d_vld)    lq_2_rob.ret_rdy = 2;
        else if (state[head].d_vld)                             lq_2_rob.ret_rdy = 1;
        else                                                    lq_2_rob.ret_rdy = 0;
        lq_2_rob.lq_ret_complete = (used == 0) ? '1 : '0;        

    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            tail_dbl <= 0;
            state   <= '0;
        end else begin
            used    <= used + dis_2_lq.lq_d_en_cnt - rob_2_lq.r_en;
            head    <= (head + rob_2_lq.r_en) % LSQ_SZ;
            tail    <= (tail + dis_2_lq.lq_d_en_cnt) % LSQ_SZ;
            tail_dbl <= (tail_dbl + dis_2_lq.lq_d_en_cnt) % LSQ_SZ_DBL;
            
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
            // $display("d_en_cnt: %d", d_in.d_en_cnt);
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= dis_2_lq.lq_d_en_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    lq_idx     : d_idxs[i],
                    rob_idx : dis_2_lq.rob_idx[i],
                    addr     : '0,
                    d_vld     : '0,
                    mem_size : '0
                };
            end

            `ifdef DEBUG
            $display("  %3d | >> LQ", $time);
            for (int i = 0; i < LSQ_SZ; i++) begin
                $display("Entry [%0d]: id=%0d, rob_idx=%0d, addr=%0d, d_valid=%b, mem_size=%0d",
                i,
                state[i].lq_idx,
                state[i].rob_idx,
                state[i].addr,
                state[i].d_vld,
                state[i].mem_size
                );
            end
            $display("  %3d | << LQ", $time);
            `endif
        end
    end


endmodule