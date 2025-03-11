`include "sys_defs.svh"


module dispatch #(parameter 
    N=`N
) (
    input clock, reset, flush,


    // DECODE
    input struct packed {
        ID_RESULT   [N-1:0]     d_dat;
    } decode_in,

    output struct packed {
        logic       [$clog2(N):0] decode_d_en_cnt;
    } decode_out,
    

    // RS
    input struct packed {
        logic       [$clog2(N):0] rs_rdy_scnt;
            // - From: RS
    } rs_in,

    output struct packed {
        logic       [$clog2(N):0] rs_d_en_cnt;
            // - To: RS
            // - Number of enabled dispatch lines? (replacement for d_vld)
            // - Question: permit
            // 1) only N dispatches, OR
            // 2) a different limit number of dispatches DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
            // (DIS_MAX will be a new sys_defs.svh constant) ?
        // ID_RESULT   [N-1:0] d_dat, //shouldn't have dispatch feed to RS,
            // - To: RS               //should come directly from dispatch
    } rs_out,
    
    
    // ROB
    input struct packed {
        logic    [$clog2(N):0]    rob_rdy_scnt;
            // From: ROB
            // saturating counter for number of free rob entries
    } rob_in,

    output struct packed {
        [$clog2(N):0]            rob_d_en_cnt;
            // To: ROB
            // - Number of enabled dispatch lines?
        // ROB_ENTRY   [N-1:0]      d_dat, //shouldn't have dispatch feed to ROB,
            // To: ROB                     //should come directly from dispatch
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } rob_out,
    

    // Free list
    input struct packed {
        logic    [$clog2(N):0]    free_rdy_scnt;
        // From: Free list
        // - sat. count of number of free pregs in free list;
        //   count reflects any pregs returned in retire! (i.e. AFTER retires)
        PHYS_REG_IDX [N-1:0]     d_ts;
        // From: Free list
        // - newly allocated pregs
        // THIS WILL BE 1 CLOCK CYCLE BEHIND. THIS IS DESIRED SO THAT
        // TAGS ARE APPLIED AT THE CORRECT TIMES (paired with map table output)
        // (means that tags will be applied when the dispatched insts actually get
        // to RS/ROB)
    } free_in,

    output struct packed {
        logic     [$clog2(N):0]  free_d_en_cnt;
            // To: Free list
            // - number of enabled dispatch lines WHO NEED A DEST PREG 
            //   (e.g. no stores)
            //   (i.e. may only be a strict subset of dispatching insns!)
    } free_out,


    // LSQ
    input struct packed {
        logic    [$clog2(N):0]    lsq_rdy_scnt;
    } lsq_in,

    output struct packed {
        logic     [$clog2(N):0]  lsq_d_en_cnt;
            // To: LSQ
            // - number of enabled dispatch lines WHO NEED A LD/ST 
            //   (i.e. may only be a strict subset of dispatching insns!)
    } lsq_out,
    
    
    // Map table
    output struct packed {
        logic         [$clog2(N):0] en_cnt;
            // - Number of enabled dispatch lines?
            // - NOTE: For in-order stuff with serial deps (like dispatch), use c(ou)nts;
            // otherwise use en(able) buses.
        // REG_IDX       [N-1:0] src1s,
        // output REG_IDX       [N-1:0] src2s,
        REG_IDX       [N-1:0] dsts;
        PHYS_REG_IDX  [N-1:0] ts;
            // To: Map table
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
        // THIS WILL BE 1 CLOCK CYCLE BEHIND. THIS IS DESIRED SO THAT
        // TAGS ARE APPLIED AT THE CORRECT TIMES (paired with free list tag output)
        // (means that tags will be applied when the dispatched insts actually get
        // to RS/ROB)
    } map_out,
    
    //dispatch shouldn't need to read from the map table.
    //dispatch will pair a new tag (from free list) with
    //the dest reg (from decode), and output the paired
    //item to the map table for it to decide how to update.
);

logic dispatch_cnt;

//logic for rs, rob, decode
always_comb begin
    
    //logic to find the minimum # of spots free across the 4 inputs
    dispatch_cnt = rs_in.rs_rdy_scnt & rob_in.rob_rdy_scnt 
                            & free_in.free_rdy_scnt & lsq_in.lsq_rdy_scnt;
    dispatch_cnt = (reset || flush) ? '0 : dispatch_cnt;

    //assigning output #'s
    decode_out.decode_d_en_cnt = dispatch_cnt;
    rs_out.rs_d_en_cnt = dispatch_cnt;
    rob_out.rob_d_en_cnt = dispatch_cnt;
    lsq_out.lsq_d_en_cnt = dispatch_cnt; //this will likely need to be changed once memory operations are introduced
end

//logic for free list
always_comb begin
    logic [$clog2(N):0] d_reg_cnt = '0;

    for (int i = 0; i < dispatch_cnt; i++) begin
        if (!decode.d_dat[i].mult && !decode.d_dat[i].wr_mem 
            && !decode.d_dat[i].cond_branch && !decode.d_dat[i].uncond_branch 
            && !decode.d_dat[i].halt) d_reg_cnt += 1;
    end

    free_out.free_d_en_cnt = (d_reg_cnt == 0) ? '0 : (d_reg_cnt == N) ? '1 : 2'b01;
    free_out.free_d_en_cnt = (reset || flush) ? '0 : free_out.free_d_en_cnt;
end

//logic for map table
PHYS_REG_IDX [N-1:0] claimed_tags;
PHYS_REG_IDX [N-1:0] dest_regs;

always_ff @(posedge clock) begin
    if (reset || flush) begin
        claimed_tags <= '0;
        dest_regs <= '0;
    end
    else begin
        claimed_tags <= free_in.d_ts;
        for (int i = 0; i < N; i++) dest_regs[i] = decode_in.d_dat[i].t;
    end
end

always_comb begin
    for (int i = 0; i < N; i++) begin
        if (claimed_tags[i] != '0) begin
            map_out.dsts[i] = dest_regs[i];
            map_out.ts[i] = claimed_tags[i];
        end
        else begin
            map_out.dsts[i] = '0;
            map_out.ts[i] = '0;
        end
    end
end


endmodule


