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

logic dispatch_cnt;
logic [$clog2(N):0] a;
logic [$clog2(N):0] b;

//logic for rs, rob, decode
always_comb begin
    // decode_out.decode_d_en_cnt = '0;
    // rs_out.rs_d_en_cnt = '0;
    // rob_out.rob_d_en_cnt = '0;
    // lsq_out.lsq_d_en_cnt = '0;
    
    //logic to find the minimum # of spots free across the 4 inputs
    // dispatch_cnt = rs_in.rs_rdy_scnt & rob_in.rob_rdy_scnt 
    //                         & free_in.free_rdy_scnt & lsq_in.lsq_rdy_scnt;
    // dispatch_cnt = (reset || flush) ? '0 : dispatch_cnt;
    a = (rs_in.rs_rdy_scnt < rob_in.rob_rdy_scnt) ? rs_in.rs_rdy_scnt : rob_in.rob_rdy_scnt;
    b = (free_in.free_rdy_scnt < lsq_in.lsq_rdy_scnt) ? free_in.free_rdy_scnt : lsq_in.lsq_rdy_scnt;
    dispatch_cnt = (a < b) ? a : b;
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
        // if (!decode_in.d_dat[i].wr_mem && !decode_in.d_dat[i].cond_branch 
        //     && !decode_in.d_dat[i].uncond_branch && !decode_in.d_dat[i].halt) begin
        //         d_reg_cnt += 1;
        //         dest_free_match[i] = 1'b1;
        // end
        if (!decode_in.d_dat[i].inst.r.rd != 0) begin
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

    //handling dest tags
    if (reset || flush) begin
        map_out.dsts = '0;
        map_out.ts = '0;
    end
    // else if (dest_free_match[i] != 1'b0) begin
        // map_out.dsts[i] = decode_in.d_dat[i].inst.r.rd;
        // map_out.ts[i] = free_in.d_ts[i];
    // end
    else if (dest_free_match == 2'b11) begin
        map_out.dsts[0] = decode_in.d_dat[0].inst.r.rd;
        map_out.ts[0] = free_in.d_ts[0];
        map_out.dsts[1] = decode_in.d_dat[1].inst.r.rd;
        map_out.ts[1] = free_in.d_ts[1];
    end
    else if (dest_free_match == 2'b10) begin
        map_out.dsts[0] = decode_in.d_dat[0].inst.r.rd;
        map_out.ts[0] = 0;
        map_out.dsts[1] = decode_in.d_dat[1].inst.r.rd;
        map_out.ts[1] = free_in.d_ts[0];
    end
    else if (dest_free_match == 2'b01) begin
        map_out.dsts[0] = decode_in.d_dat[0].inst.r.rd;
        map_out.ts[0] = free_in.d_ts[0];
        map_out.dsts[1] = decode_in.d_dat[1].inst.r.rd;
        map_out.ts[1] = 0;
    end
    else begin
        map_out.dsts = '0;
        map_out.ts = '0;
    end

    //handling src tags
    for (int i = 0; i < N; i++) begin
        
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
        else if (decode_in.d_dat[i].opa_select == OPA_IS_RS1) begin
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


