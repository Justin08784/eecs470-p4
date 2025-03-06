`include "sys_defs.svh"

/* 
================================================
Free List
================================================
*/
module free_list #(parameter 
    N=`N
) (
    input clock, reset, flush,
    // retire
    input struct packed {
        logic     [$clog2(N):0]   r_en_cnt;
            // From: retire (ROB)
            // - number of enabled retire lines WHO ARE RETURNING/DEALLOC'ING A PREG
            //   (e.g. no stores)
            //   (i.e. may only be a strict subset of retiring insns!)
            // - Question: Does this really need to be an count? Surely there isn't
            //   any serial dep. between returning pregs no? But again, the free list
            //   itself is likely going to be FIFO so I'm not sure what's more performant...
            //   enable bus vs. count?
        PHYS_REG_IDX [N-1:0]     r_tolds;
            // From: retire (ROB)
            // - pregs being returned to free list
    } r_in,

    // complete ?? 
    // issue ??

    // dispatch
    input struct packed {
        logic     [$clog2(N):0]   d_en_cnt;
            // From: dispatch
            // - number of enabled dispatch lines WHO NEED A DEST PREG 
            //   (e.g. no stores)
            //   (i.e. may only be a strict subset of dispatching insns!)
            // - depends on d_out.free_rdy_scnt

    } d_in,
    
    output struct packed {
        logic    [$clog2(N):0]   free_rdy_scnt;
            // To: dispatch
            // - sat. count of number of free pregs in free list;
            //   count reflects any pregs returned in retire! (i.e. AFTER retires)
            // - depends on r_in
        PHYS_REG_IDX [N-1:0]     d_ts;
            // To: dispatch
            // - newly allocated pregs
            // - depends on d_in.d_en_cnt
    } d_out
);
    // TODO: need reset states for head, tail, cnt as well!!
    function automatic [`PHYS_REG_SZ_R10K-1:0][$bits(PHYS_REG_IDX)-1:0] gen_reset_state();
        logic [`PHYS_REG_SZ_R10K-1:0][$bits(PHYS_REG_IDX)-1:0] state;
        logic [$bits(PHYS_REG_IDX)-1:0] start = 32 + 1;
        for (int unsigned i = 0; i < $unsigned(`PHYS_REG_SZ_R10K); ++i) begin
            state[i] = start + i;
        end
        return state;
    endfunction
    const logic [`PHYS_REG_SZ_R10K-1:0][$bits(PHYS_REG_IDX)-1:0] RESET_STATE = gen_reset_state();
   

    fifo #(
        .DEPTH(`PHYS_REG_SZ_R10K),
        .WIDTH($bits(PHYS_REG_IDX)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .MAX_SCNT(`N),
        .RESET_STATE('0)
    ) lst (
        .clock(clock),
        .reset(reset),

        .wr_en_cnt(r_in.r_en_cnt),
        .wr_data(r_in.r_tolds),

        .rd_en_cnt(d_in.d_en_cnt),
        .rd_data(d_out.d_ts),

        .free_scnt(d_out.free_rdy_scnt),
        .used_scnt() // do we need this? how would even retire return more pregs than in existence?
    );

endmodule