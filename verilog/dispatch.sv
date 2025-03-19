`include "sys_defs.svh"
// `include "psel_gen.sv"

module dispatch #(parameter 
    N=`N
) (
    input clock, reset, flush,
    // DECODE
    input   decode2dispatch decode_in,
    output  dispatch2decode decode_out,
    
    // RS
    input   rs2dispatch rs_in,
    output  dispatch2rs rs_out,

    // ROB
    input   rob2dispatch rob_in,
    output  dispatch2rob rob_out,
    
    // Free list
    input   free_list2dispatch free_in,
    output  dispatch2free_list free_out,

    // LSQ
    input   lsq2dispatch lsq_in,
    output  dispatch2lsq lsq_out,
    
    // Map table
    input   map_table2dispatch map_in,
    output  dispatch2map_table map_out
    
);

logic [$clog2(N):0] dispatch_cnt;

// control logic
always_comb begin
    //logic to find the minimum # of spots free across the 4 inputs
    dispatch_cnt = `MIN(rs_in.rs_rdy_scnt, rob_in.rob_rdy_scnt);
    dispatch_cnt = `MIN(dispatch_cnt, decode_in.d_vld_scnt);
    // dispatch_cnt = `MIN(dispatch_cnt, lsq_in.lsq_rdy_scnt); // TODO: enable later
    dispatch_cnt = free_in.free_rdy_scnt < $countones(decode_in.prvw_has_dests)
        ? `MIN(dispatch_cnt, free_in.free_rdy_scnt)
        : dispatch_cnt;
    dispatch_cnt = `MIN(dispatch_cnt,decode_in.d_vld_scnt);

    //assigning output #'s
    decode_out.dispatch_en_cnt  = dispatch_cnt;
    lsq_out.lsq_d_en_cnt        = dispatch_cnt; //this will likely need to be changed once memory operations are introduced
end

//logic for free list
logic [$clog2(N):0]     num_alloc_free;
logic [N-1:0]           dispatch_en;
logic [N-1:0][N-1:0]    gbus_preg2insn;
always_comb begin
    //determining how many instructions have a dest reg
    for (int unsigned i = 0; i < N; ++i)
        dispatch_en[i] = i < dispatch_cnt;

    num_alloc_free = $countones(decode_in.prvw_has_dests & dispatch_en);
    free_out.free_d_en_cnt = num_alloc_free;
end

psel_gen #(
    .WIDTH  (N),
    .REQS   (N)
) sel (
    .req    (decode_in.prvw_has_dests & dispatch_en),
    .gnt_bus(gbus_preg2insn)
);

// handle map table output 
always_comb begin
    map_out.en_cnt  = dispatch_cnt;
    map_out.src1s   = '0;
    map_out.src2s   = '0;
    map_out.dsts    = '0;
    map_out.ts      = '0;

    //handling dest tags
    foreach (gbus_preg2insn[i, j]) begin
        if (gbus_preg2insn[i][j])
            map_out.ts[j] |= free_in.d_ts[i];
    end

    for (int i = 0; i < dispatch_cnt; i++) begin

        //handling dest register
        map_out.dsts[i]     = decode_in.d_dat[i].inst.r.rd;
        //handling src tags
        map_out.src1s[i]    = decode_in.d_dat[i].inst.r.rs1;
        map_out.src2s[i]    = decode_in.d_dat[i].inst.r.rs2;

        // TODO: specifics of setting source registers need to be considered carefully!
        // //handling src1s tags
        // if (decode_in.d_dat[i].opa_select == OPA_IS_RS1) begin
        //     map_out.src1s[i] = decode_in.d_dat[i].inst.r.rs1;
        // //left these two separate in case we discover that they need to be handled differently
        // end else if (decode_in.d_dat[i].cond_branch) begin
        //     map_out.src1s[i] = decode_in.d_dat[i].inst.r.rs1;
        // end else if (decode_in.d_dat[i].wr_mem) begin
        //     map_out.src1s[i] = decode_in.d_dat[i].inst.r.rs1;
        // end

        // //handling src2s tags
        // if (decode_in.d_dat[i].opb_select == OPB_IS_RS2) begin
        //     map_out.src2s[i] = decode_in.d_dat[i].inst.r.rs2;
        // //left these two separate in case we discover that they need to be handled differently
        // end else if (decode_in.d_dat[i].cond_branch) begin
        //     map_out.src2s[i] = decode_in.d_dat[i].inst.r.rs2;
        // end else if (decode_in.d_dat[i].wr_mem) begin
        //     map_out.src2s[i] = decode_in.d_dat[i].inst.r.rs2;
        // end
    end
end

// handle rs output 
always_comb begin
    rs_out.d_en_cnt = dispatch_cnt;
    rs_out.d_dat = '0;

    for (int i = 0; i < dispatch_cnt; i++) begin
        rs_out.d_dat[i]            = decode_in.d_dat[i];

        rs_out.d_dat[i].t          = map_out.ts[i];
        rs_out.d_dat[i].t1         = map_in.t1s[i];
        rs_out.d_dat[i].t2         = map_in.t2s[i];
        rs_out.d_dat[i].t1_rdy     = map_in.cpl1s[i];
        rs_out.d_dat[i].t2_rdy     = map_in.cpl2s[i];

        rs_out.d_dat[i].rob_idx    = rob_in.rob_idxs[i];
    end
end

// handle rob output 
always_comb begin
    rob_out = '0;
    rob_out.d_en_cnt = dispatch_cnt;

    for (int i = 0; i < dispatch_cnt; i++) begin
        //handling dest register
        rob_out.dst[i]      = decode_in.d_dat[i].inst.r.rd;
        //handling src tags
        rob_out.tag[i]      = map_out.ts[i];
        rob_out.t_old[i]    = map_in.ts_old[i];

        rob_out.halt[i]     = decode_in.d_dat[i].halt;
        rob_out.illegal[i]  = decode_in.d_dat[i].illegal;
        rob_out.NPC[i]      = decode_in.d_dat[i].NPC;
        $display("DISPATCH: %1d", rob_out.halt[i]);
        $display("DISPATCH ILLEGAL: %1d",rob_out.illegal[i]);
    end
end


endmodule


