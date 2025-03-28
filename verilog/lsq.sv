`include "sys_defs.svh"


module lsq #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
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
    output lsq2mem lsq_2_mem
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

    // assign lsq_2_dis.sq_tail       = tail;

    // assign lsq_2_rs.en          = exec_2_lsq.ex_en;
    // assign lsq_2_rs.sq_idx_cdb  = exec_2_lsq.sq_idx;
    LSQ_IDX head_plus_one;

    always_comb begin
        // lsq2rs = '0;
        lsq_2_exec = '0;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;

        // handle dispatch (outs)
        lsq_2_dis <= '{
            // rob_rdy_scnt : `MIN(free + r_out.r_en_cnt, NUM_DPORTS),
            sq_rdy_scnt : `MIN(free, NUM_DPORTS),
            sq_tail     : tail
        };

        //handle LSQ CDB to RS
        lsq_2_rs <= '{
            // rob_rdy_scnt : `MIN(free + r_out.r_en_cnt, NUM_DPORTS),
            en : exec_2_lsq.ex_en,
            sq_idx_cdb     : exec_2_lsq.sq_idx
        };

        //handle lsq to ROB for retirement
        head_plus_one = (head + 1) % LSQ_SZ;
        if (state[head].d_vld && state[head_plus_one].d_vld)    lsq_2_rob.ret_rdy = 2;
        else if (state[head].d_vld)                             lsq_2_rob.ret_rdy = 1;
        else                                                    lsq_2_rob.ret_rdy = 0;

        //handle retirement write to mem

    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            state   <= '0;
        end else begin
            // `ifndef SYNTH
            // if (d_in.d_en_cnt > free + r_out.r_en_cnt)
            //     $error("ROB overflow!");
            // if (r_out.r_en_cnt > used + d_in.d_en_cnt)
            //     $error("ROB underflow!");
            // `endif
            used    <= used + dis_2_lsq.lsq_d_en_cnt - rob_2_lsq.r_en;
            head    <= (head + rob_2_lsq.r_en) % LSQ_SZ;
            tail    <= (tail + dis_2_lsq.lsq_d_en_cnt) % LSQ_SZ;

            // handle complete (ins)
            // for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
            //     cur_idx = c_in.c_rob_idxs[i];

            //     /* V1: This doesn't actually update the cpl bit... */
            //     // state[cur_idx].cpl <= state[cur_idx].cpl || c_in.c_en[i];
            //     /* V2: ...but this one does???! Make this make sense? */
            //     if (c_in.c_en[i])
            //         state[cur_idx].cpl <= 1;
            // end

            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
                cur_idx = exec_2_lsq.sq_idx[i];

                if (exec_2_lsq.ex_en[i]) begin
                    state[cur_idx].addr <= exec_2_lsq.addr[i];
                    state[cur_idx].data <= exec_2_lsq.data[i];
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
                    sq_idx     : cur_idx,
                    rob_idx : dis_2_lsq.rob_idx[i],
                    addr     : '0,
                    data   : '0,
                    d_vld     : '0
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
    NUM_FU_STORE=`NUM_FU_STORE,
    NUM_FU_LOAD=`NUM_FU_LOAD
) (
    input clock,
    input reset,
    input flush,

    input SQ_ENTRY [N-1:0] ret_st,

    output logic [$clog2(N):0] free,
    output logic empty
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

    // assign lsq_2_dis.sq_tail       = tail;

    // assign lsq_2_rs.en          = exec_2_lsq.ex_en;
    // assign lsq_2_rs.sq_idx_cdb  = exec_2_lsq.sq_idx;
    LSQ_IDX head_plus_one;

    always_comb begin
        // lsq2rs = '0;
        lsq_2_exec = '0;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;

        // handle dispatch (outs)
        lsq_2_dis <= '{
            // rob_rdy_scnt : `MIN(free + r_out.r_en_cnt, NUM_DPORTS),
            sq_rdy_scnt : `MIN(free, NUM_DPORTS),
            sq_tail     : tail
        };

        //handle lsq to ROB for retirement
        head_plus_one = (head + 1) % LSQ_SZ;
        if (state[head].d_vld && state[head_plus_one].d_vld)    lsq_2_rob.ret_rdy = 2;
        else if (state[head].d_vld)                             lsq_2_rob.ret_rdy = 1;
        else                                                    lsq_2_rob.ret_rdy = 0;

        //handle retirement write to mem

    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            state   <= '0;
        end else begin
            // `ifndef SYNTH
            // if (d_in.d_en_cnt > free + r_out.r_en_cnt)
            //     $error("ROB overflow!");
            // if (r_out.r_en_cnt > used + d_in.d_en_cnt)
            //     $error("ROB underflow!");
            // `endif
            used    <= used + dis_2_lsq.lsq_d_en_cnt - rob_2_lsq.r_en;
            head    <= (head + rob_2_lsq.r_en) % LSQ_SZ;
            tail    <= (tail + dis_2_lsq.lsq_d_en_cnt) % LSQ_SZ;

            // handle complete (ins)
            // for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
            //     cur_idx = c_in.c_rob_idxs[i];

            //     /* V1: This doesn't actually update the cpl bit... */
            //     // state[cur_idx].cpl <= state[cur_idx].cpl || c_in.c_en[i];
            //     /* V2: ...but this one does???! Make this make sense? */
            //     if (c_in.c_en[i])
            //         state[cur_idx].cpl <= 1;
            // end

            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_ST_PORTS; ++i) begin
                cur_idx = exec_2_lsq.sq_idx[i];

                if (exec_2_lsq.ex_en[i]) begin
                    state[cur_idx].addr <= exec_2_lsq.addr[i];
                    state[cur_idx].data <= exec_2_lsq.data[i];
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
                    sq_idx     : cur_idx,
                    rob_idx : dis_2_lsq.rob_idx[i],
                    addr     : '0,
                    data   : '0,
                    d_vld     : '0
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