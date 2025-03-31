`include "sys_defs.svh"
// `include "psel_gen.sv"

/*
[RESOLVED]
================= WARNING =================
This version of dispatch lacks a real RS/ROB reservation system in the alloc stage.
Currently relies on oversized RS/ROB to "absorb" long dependency chains in tests.

e.g.
With RS=16 and ROB=64, test2.s and branchy.s run correctly. But mult_no_lsq.s,
a long-running program, gets stuck.

With RS=128 and ROB=512, all three programs run correctly.

Q: What is happening? A:
Alloc stage overestimates available RS/ROB space because it does not
track *reserved but not yet written* entries. When the pipeline is under
heavy pressure (e.g. deep loop chains or high ILP), instructions can be 
dispatched into supposedly "free" entries, overwriting in-flight ones in
the ROB/BTQ. (I think this ovewriting is not an issue for RS because the
dispatch->RS psel does its own independent selection.)

This bug is masked when the structures are large enough to absorb the full
working set, but will break under realistic pressure.

[Initial commit of pipelined dispatch]
===========================================
*/
typedef struct packed {
    PHYS_REG_IDX    t_old;
    ID_RESULT       dat;
} RENAME_COMMIT_PKT;

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
    
    // BTQ
    input   btq2dispatch btq_in,
    output  dispatch2btq btq_out,

    // Map table
    input   map_table2dispatch map_in,
    output  dispatch2map_table map_out
    
);

/* >> ==== 1. Alloc Stage ==== >> */
logic [$clog2(N):0] alloc_en_cnt;
logic [$clog2(N):0] alloc_rdy_scnt;
logic [$clog2(N):0] alloc_vld_scnt;

// control logic
always_comb begin
    //logic to find the minimum # of spots free across the 4 inputs
    // TODO: Is syntheizer smart enough to transform this MIN compute into a tree?
    alloc_en_cnt = rob_in.rob_rdy_scnt;
    alloc_en_cnt = `MIN(alloc_en_cnt, decode_in.d_vld_scnt);
    // alloc_en_cnt = `MIN(alloc_en_cnt, lsq_in.lsq_rdy_scnt); // TODO: enable later
    alloc_en_cnt = free_in.free_rdy_scnt < $countones(decode_in.prvw_has_dests)
        ? `MIN(alloc_en_cnt, free_in.free_rdy_scnt)
        : alloc_en_cnt;
    alloc_en_cnt = btq_in.btq_rdy_scnt < $countones(decode_in.prvw_is_brch)
        ? `MIN(alloc_en_cnt, btq_in.btq_rdy_scnt)
        : alloc_en_cnt;
    alloc_en_cnt = `MIN(alloc_en_cnt, alloc_rdy_scnt);
    rob_out.alloc_rsrv_cnt  = alloc_en_cnt;
    btq_out.alloc_rsrv_cnt  = alloc_en_cnt;
    
    //assigning output #'s
    decode_out.dispatch_en_cnt  = alloc_en_cnt;
    // lsq_out.lsq_d_en_cnt        = alloc_en_cnt; //this will likely need to be changed once memory operations are introduced
end

//logic for free list
logic [N-1:0]           bus_alloc_preg;
logic [$clog2(N):0]     num_alloc_preg;
logic [N-1:0][N-1:0]    gbus_preg2insn;
always_comb begin
    //determining how many instructions have a dest reg
    foreach (bus_alloc_preg[i])
        bus_alloc_preg[i] = (i < alloc_en_cnt) && decode_in.prvw_has_dests[i]; 

    num_alloc_preg = $countones(bus_alloc_preg);
    free_out.free_d_en_cnt = num_alloc_preg;
end

psel_gen #(
    .WIDTH  (N),
    .REQS   (N)
) sel (
    .req    (bus_alloc_preg),
    .gnt_bus(gbus_preg2insn)
);

ID_RESULT [`N-1:0] tmp_decode2alloc;
always_comb begin
    tmp_decode2alloc = '0;
    for (int unsigned i = 0; i < `N; ++i)
        tmp_decode2alloc[i] = decode_in.d_dat[i];

    //handling dest tags
    foreach(gbus_preg2insn[i, j]) begin
        if (gbus_preg2insn[i][j])
            tmp_decode2alloc[j].t |= free_in.d_ts[i];
    end
end

ID_RESULT [`N-1:0]  rename_in;
logic [$clog2(N):0] rename_vld_scnt;
logic [$clog2(N):0] rename_rdy_scnt;
logic [$clog2(N):0] rename_en_cnt;
logic [`N-1:0]      rename_en;
fifo #(
    .INSTANCE_ID(39),
    .DEPTH(2*`N),
    .WIDTH($bits(ID_RESULT)),
    .NUM_RPORTS(`N),
    .NUM_WPORTS(`N),
    .ENABLE_INTR_FWD(`FALSE)
) alloc_buf (
    .clock      (clock),
    .reset      (reset),
    .flush      (flush),
    .wr_en_cnt  (alloc_en_cnt),
    .wr_data    (tmp_decode2alloc),
    .rd_en_cnt  (rename_en_cnt),
    .rd_data    (rename_in),

    .free_scnt  (alloc_rdy_scnt),
    .used_scnt  (alloc_vld_scnt)
);

/* >> ==== 2. Rename Stage ==== >> */
/* >> ==== 3. Commit Stage ==== >> */
always_comb begin
    rename_en_cnt = `MIN(alloc_vld_scnt, rs_in.rs_rdy_scnt);
    rename_en_cnt = `MIN(rename_en_cnt,  rename_rdy_scnt);
    rs_out.alloc_rsrv_cnt = rename_en_cnt;
    foreach(rename_en[i])
        rename_en[i] = i < rename_en_cnt;
end

// handle btq output
logic [`N-1:0] is_brch;
logic [`N-1:0][`N-1:0] brch_packed_idx;
always_comb begin
    foreach(is_brch[i])
        is_brch[i] = rename_in[i].is_branch;

    // pack branch insns to lowest indices
    brch_packed_idx = '0;
    for (int unsigned i = 0, int wr_idx = 0; i < `N; ++i) begin
        if (!is_brch[i])
            continue;
        brch_packed_idx[i] = wr_idx;
        btq_out.NPC[wr_idx] = rename_in[i].NPC;
        ++wr_idx;
    end

    btq_out.en_cnt = $countones(rename_en & is_brch);
end

// handle map table output 
always_comb begin
    map_out         = '0;
    map_out.en_cnt  = rename_en_cnt;

    for (int i = 0; i < rename_en_cnt; i++) begin
        //handling dest register
        map_out.ts[i]        = rename_in[i].t;
        map_out.dsts[i]      = rename_in[i].dest_reg_idx;
        // actually need src tags?
        map_out.rd_src1s[i]  = rename_in[i].opa_select == OPA_IS_RS1
            || rename_in[i].cond_branch;
        map_out.rd_src2s[i]  = rename_in[i].opb_select == OPB_IS_RS2
            || rename_in[i].cond_branch
            || rename_in[i].wr_mem;
        //handling src tags
        map_out.src1s[i]    = rename_in[i].inst.r.rs1;
        map_out.src2s[i]    = rename_in[i].inst.r.rs2;
    end
end

RENAME_COMMIT_PKT [`N-1:0] tmp_alloc2rename;
always_comb begin
    tmp_alloc2rename = '0;
    for (int i = 0; i < rename_en_cnt; i++) begin
        tmp_alloc2rename[i].dat         = rename_in[i];

        tmp_alloc2rename[i].dat.t       = map_out.ts[i];
        tmp_alloc2rename[i].t_old       = map_in.ts_old[i];
        tmp_alloc2rename[i].dat.t1      = map_in.t1s[i];
        tmp_alloc2rename[i].dat.t2      = map_in.t2s[i];
        tmp_alloc2rename[i].dat.t1_rdy  = map_in.cpl1s[i];
        tmp_alloc2rename[i].dat.t2_rdy  = map_in.cpl2s[i];

        tmp_alloc2rename[i].dat.rob_idx = rob_in.rob_idxs[i];
        tmp_alloc2rename[i].dat.btq_idx = rename_in[i].is_branch
            ? btq_in.btq_idxs[brch_packed_idx[i]]
            : '0;
    end
end

RENAME_COMMIT_PKT [`N-1:0]  commit_in;
logic [$clog2(N):0] commit_en_cnt;
logic [`N-1:0]      commit_en;
fifo #(
    .INSTANCE_ID(40),
    .DEPTH(2*`N),
    .WIDTH($bits(RENAME_COMMIT_PKT)),
    .NUM_RPORTS(`N),
    .NUM_WPORTS(`N),
    .ENABLE_INTR_FWD(`FALSE)
) rename_buf (
    .clock      (clock),
    .reset      (reset),
    .flush      (flush),
    .wr_en_cnt  (rename_en_cnt),
    .wr_data    (tmp_alloc2rename),
    .rd_en_cnt  (commit_en_cnt),
    .rd_data    (commit_in),

    .free_scnt  (rename_rdy_scnt),
    .used_scnt  (rename_vld_scnt)
);

// handle rs output 
always_comb begin
    commit_en_cnt   = rename_vld_scnt;
    rs_out.d_dat    = '0;
    rs_out.d_en_cnt = commit_en_cnt;

    for (int i = 0; i < commit_en_cnt; i++)
        rs_out.d_dat[i] = commit_in[i].dat;
end

// handle rob output 
always_comb begin
    rob_out.d_en_cnt = commit_en_cnt;

    for (int i = 0; i < commit_en_cnt; i++) begin
        //handling src tags
        rob_out.is_brch[i]  = commit_in[i].dat.is_branch;
        rob_out.tag[i]      = commit_in[i].dat.t;
        rob_out.t_old[i]    = commit_in[i].t_old;
        //handling dest register
        rob_out.dst[i]      = commit_in[i].dat.dest_reg_idx;

        rob_out.halt[i]     = commit_in[i].dat.halt;
        rob_out.illegal[i]  = commit_in[i].dat.illegal;
    end
end

// debug
`ifdef DEBUG
always_ff @(posedge clock) begin

    if (!reset) begin
        $display("  %3d | >> Dispatch >>", $time);
        $display("rs_in.rs_rdy_scnt: %d",   rs_in.rs_rdy_scnt);
        $display("btq_in.btq_rdy_scnt: %d",   btq_in.btq_rdy_scnt);
        $display("rob_in.rob_rdy_scnt: %d",  rob_in.rob_rdy_scnt);
        $display("decode_in.d_vld_scnt: %d",  decode_in.d_vld_scnt);
        $display("free_in.free_rdy_scnt: %d",  free_in.free_rdy_scnt);
        $display("decode_in.prvw_has_dests: %b", decode_in.prvw_has_dests);
        $display("  %3d | << Dispatch <<", $time);
    end

end
`endif

endmodule


