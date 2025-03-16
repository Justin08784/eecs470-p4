`include "sys_defs.svh"


module dispatch #(parameter 
    N=`N
) (
    input clock, reset, flush,
    output ID_RESULT [N-1:0] d_dat,

    // DECODE
    input decode2dispatch decode_in,
    output dispatch2decode decode_out,
    
    // RS
    input rs2dispatch rs_in,
    output dispatch2rs rs_out,

    // ROB
    input rob2dispatch rob_in,
    output dispatch2rob rob_out,
    
    // Free list
    input free_list2dispatch free_in,
    output dispatch2free_list free_out,

    // LSQ
    input lsq2dispatch lsq_in,
    output dispatch2lsq lsq_out,
    
    // Map table
    input map_table2dispatch map_in,
    output dispatch2map_table map_out
    
    //dispatch shouldn't need to read from the map table.
    //dispatch will pair a new tag (from free list) with
    //the dest reg (from decode), and output the paired
    //item to the map table for it to decide how to update.
);

logic [$clog2(N):0] dispatch_cnt;

//logic for rs, rob, decode, lsq
always_comb begin
    
    //logic to find the minimum # of spots free across the 4 inputs
    dispatch_cnt = `MIN(`MIN(rs_in.rs_rdy_scnt,rob_in.rob_rdy_scnt),`MIN(free_in.free_rdy_scnt,lsq_in.lsq_rdy_scnt));
    dispatch_cnt = (reset || flush) ? '0 : (`MIN(dispatch_cnt,2));
    
    //assigning output #'s
    decode_out.decode_d_en_cnt = (dispatch_cnt == 2) ? 2'b11 : ((dispatch_cnt == 1) ? 2'b01 : 2'b00);
    rs_out.rs_d_en_cnt = dispatch_cnt;
    rob_out.d_en_cnt = dispatch_cnt;
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

//logic for map table output 
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

//logic for map table input
always_comb begin
    d_dat = '0;

    if (!(reset || flush)) begin
        for (int i = 0; i < dispatch_cnt; i++) begin
            d_dat[i] = decode_in.d_dat[i];

            d_dat[i].t = map_in.ts[i];
            d_dat[i].t1 = map_in.t1s[i];
            d_dat[i].t2 = map_in.t2s[i];
            d_dat[i].t1_rdy = map_in.cpl1s[i];
            d_dat[i].t2_rdy = map_in.cpl2s[i];

            d_dat[i].rob_idx = rob_in.rob_idxs[i];
        end
    end
end


endmodule


