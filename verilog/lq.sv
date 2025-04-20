`include "sys_defs.svh"


module lq #(parameter 
    N=`N,
    LSQ_SZ=`LSQ_SZ,
    // LSQ_SZ_DBL=`LSQ_SZ_DBL,
    NUM_FU_STORE=`NUM_FU_STORE,
    NUM_FU_LOAD=`LD_BAY_SZ
) (
    `ifdef DEBUG
    output DBG_lq dbg,
    `endif 

    input clock,
    input reset,
    input flush,

    input dispatch2lq dispatch_in,
    input execute2lq execute_in,
    input retire2lq retire_in,
    input sq2lq sq_in,

    output lq2dispatch dispatch_out,
    output lq2retire retire_out,
    output lq2sq sq_out
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


    logic [LSQ_SZ-1:0] set_err;
    LSQ_IDX [LSQ_SZ-1:0] err_idx;

    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % LSQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % LSQ_SZ;
    end

    always_comb begin
        // handle dispatch (outs)
        dispatch_out = '{
            lq_rdy_scnt : free_scnt,
            lq_tail     : tail,
            next_ids    : d_idxs
        }; 
    end

    always_comb begin
        //handle telling fetch the top 2 PC's
        retire_out.PC[0] = state[r_idxs[0]].inst_pc;
        retire_out.PC[1] = state[r_idxs[1]].inst_pc;
        retire_out.err_ld_ooo[0] = state[r_idxs[0]].err_ld_ooo;
        retire_out.err_ld_ooo[1] = state[r_idxs[1]].err_ld_ooo;
    end


    always_comb begin
        sq_out = '0;

        foreach(execute_in.ld_ex_en[i]) begin
            // if (!execute_in.ld_ex_en[i]) continue;

            sq_out.ck_en[i] = execute_in.ld_ex_en[i];// && (state[execute_in.ld_lq_idx[i]].sq_idx != LSQ_SZ);
            sq_out.idxs[i] = state[execute_in.ld_lq_idx[i]].sq_idx;
        end
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
            used    <= used + dispatch_in.lq_d_en_cnt - retire_in.r_en;
            free    <= free - dispatch_in.lq_d_en_cnt + retire_in.r_en;
            rsvd    <= rsvd + dispatch_in.rename_en_cnt - dispatch_in.lq_d_en_cnt;

            head    <= (head + retire_in.r_en) % LSQ_SZ;
            tail    <= (tail + dispatch_in.lq_d_en_cnt) % LSQ_SZ;
            
            // handle execute updates
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_FU_LOAD; ++i) begin
                cur_idx = execute_in.ld_lq_idx[i];

                if (execute_in.ld_ex_en[i]) begin
                    state[cur_idx].addr <= execute_in.ld_addr[i];
                    state[cur_idx].mem_size <= execute_in.ld_mem_size[i];
                    state[cur_idx].d_vld <= '1;
                end

            end

            //handle error flags

            foreach(sq_out.ck_en[i]) begin
                if (sq_out.ck_en[i] && sq_in.err_en[i]) state[execute_in.ld_lq_idx[i]].err_ld_ooo <= 1;
            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= dispatch_in.lq_d_en_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    sq_idx : dispatch_in.sq_idx[i],
                    addr     : '0,
                    d_vld     : '0,
                    mem_size : '0,
                    inst_pc : dispatch_in.inst_pc[i],
                    err_ld_ooo : '0
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

        dispatch_out
    };
    `endif 


endmodule