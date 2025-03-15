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
        logic       [N-1:0] decode_d_en_cnt;
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
    } rs_out,
    
    
    // ROB
    input struct packed {
        logic    [$clog2(N):0]    rob_rdy_scnt;
            // From: ROB
            // saturating counter for number of free rob entries
    } rob_in,

    output struct packed {
        logic   [$clog2(N):0]            rob_d_en_cnt;
            // To: ROB
            // - Number of enabled dispatch lines?
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
        REG_IDX       [N-1:0] src1s;
        REG_IDX       [N-1:0] src2s;
        REG_IDX       [N-1:0] dsts;
        PHYS_REG_IDX  [N-1:0] ts;
            // To: Map table
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } map_out
    
    //dispatch shouldn't need to read from the map table.
    //dispatch will pair a new tag (from free list) with
    //the dest reg (from decode), and output the paired
    //item to the map table for it to decide how to update.
);

logic [$clog2(N):0] dispatch_cnt;
logic [$clog2(N):0] min1;
logic [$clog2(N):0] min2;

//logic for rs, rob, decode, lsq
always_comb begin
    // decode_out.decode_d_en_cnt = '0;
    // rs_out.rs_d_en_cnt = '0;
    // rob_out.rob_d_en_cnt = '0;
    // lsq_out.lsq_d_en_cnt = '0;
    
    //logic to find the minimum # of spots free across the 4 inputs
    min1 = (rs_in.rs_rdy_scnt < rob_in.rob_rdy_scnt) ? rs_in.rs_rdy_scnt : rob_in.rob_rdy_scnt;
    min2 = (free_in.free_rdy_scnt < lsq_in.lsq_rdy_scnt) ? free_in.free_rdy_scnt : lsq_in.lsq_rdy_scnt;
    dispatch_cnt = (min1 < min2) ? min1 : min2;
    dispatch_cnt = (reset || flush) ? '0 : ((dispatch_cnt > 2) ? 2 : dispatch_cnt);    
    
    //assigning output #'s
    decode_out.decode_d_en_cnt = (dispatch_cnt == 2) ? 2'b11 : ((dispatch_cnt == 1) ? 2'b01 : 2'b00);
    rs_out.rs_d_en_cnt = dispatch_cnt;
    rob_out.rob_d_en_cnt = dispatch_cnt;
    lsq_out.lsq_d_en_cnt = dispatch_cnt; //this will likely need to be changed once memory operations are introduced
end

logic [N-1:0] dest_free_match;
logic [$clog2(N):0] d_reg_cnt;

//logic for free list
always_comb begin
    d_reg_cnt = '0;
    dest_free_match = '0;

    //determining how many instructions have a dest reg
    for (int i = 0; i < dispatch_cnt; i++) begin
        if (decode_in.d_dat[i].inst.r.rd != '0) begin
                d_reg_cnt += 1;
                dest_free_match[i] = 1'b1;
        end
    end

    free_out.free_d_en_cnt = (d_reg_cnt == 0) ? '0 : (d_reg_cnt == N) ? 2 : 1;
    free_out.free_d_en_cnt = (reset || flush) ? '0 : free_out.free_d_en_cnt;
end

//logic for map table
always_comb begin
    map_out.en_cnt = dispatch_cnt;
    map_out.src1s = '0;
    map_out.src2s = '0;
    map_out.dsts = '0;
    map_out.ts = '0;

    for (int i = 0; i < dispatch_cnt; i++) begin

        //handling dest register
        if (reset || flush) begin
            map_out.dsts[i] = '0;
            map_out.ts[i] = '0;
        end
        else begin
            map_out.dsts[i] = decode_in.d_dat[i].inst.r.rd;
        end

        //handling dest tags
        if (reset || flush) begin
            map_out.dsts[i] = '0;
            map_out.ts[i] = '0;
        end
        else if (dest_free_match[i]) begin
            map_out.ts[i] = free_in.d_ts[i];
        end
        else begin
            map_out.ts[i] = '0;
        end
        
        //handling src1s tags
        if (reset || flush) begin
            map_out.src1s[i] = '0;
        end
        else if (decode_in.d_dat[i].opa_select == OPA_IS_RS1) begin
            map_out.src1s[i] = decode_in.d_dat[i].inst.r.rs1;
        end
        //left these two separate in case we discover that they need to be handled differently
        else if (decode_in.d_dat[i].cond_branch) begin
            map_out.src1s[i] = decode_in.d_dat[i].inst.r.rs1;
        end
        else if (decode_in.d_dat[i].wr_mem) begin
            map_out.src1s[i] = decode_in.d_dat[i].inst.r.rs1;
        end
        else begin
            map_out.src1s[i] = '0;
        end

        //handling src2s tags
        if (reset || flush) begin
            map_out.src2s[i] = '0;
        end
        else if (decode_in.d_dat[i].opb_select == OPB_IS_RS2) begin
            map_out.src2s[i] = decode_in.d_dat[i].inst.r.rs2;
        end
        //left these two separate in case we discover that they need to be handled differently
        else if (decode_in.d_dat[i].cond_branch) begin
            map_out.src2s[i] = decode_in.d_dat[i].inst.r.rs2;
        end
        else if (decode_in.d_dat[i].wr_mem) begin
            map_out.src2s[i] = decode_in.d_dat[i].inst.r.rs2;
        end
        else begin
            map_out.src2s[i] = '0;
        end
    end
end


endmodule


