`include "sys_defs.svh"

typedef struct packed {
    PHYS_REG_IDX    t_old;
    ID_RESULT       dat;
} RENAME_COMMIT_PKT;

module dispatch #(parameter 
    N=`N
) (
    `ifdef DEBUG
    output DBG_dispatch dbg,
    `endif

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
    input   sq2dispatch sq_in,
    output  dispatch2sq sq_out,
    input   lq2dispatch lq_in,
    output  dispatch2lq lq_out,
    
    // BTQ
    input   btq2dispatch btq_in,
    output  dispatch2btq btq_out,

    // Map table
    input   execute2complete_tag ctag_in,

    // Map table
    input   map_table2dispatch map_in,
    output  dispatch2map_table map_out
    
);

logic [`PHYS_REG_SZ_R10K-1:0] cpl_lst;

/* >> ==== 1. Alloc Stage ==== >> */
logic [$clog2(N):0] alloc_en_cnt;
logic [$clog2(N):0] alloc_rdy_scnt;
logic [$clog2(N):0] alloc_vld_scnt;

logic [$clog2(N):0] lim_cnt_free;
logic [$clog2(N):0] lim_cnt_sq;
logic [$clog2(N):0] lim_cnt_lq;

// Gate by availability
always_comb begin
    // TODO: Is syntheizer smart enough to transform this MIN compute into a tree?
    alloc_en_cnt = decode_in.d_vld_scnt;
    alloc_en_cnt = `MIN(rob_in.rob_rdy_scnt, alloc_en_cnt);

    lim_cnt_free = 0;
    for (int unsigned i = 0, int used_cnt = 0; i < `N; ++i) begin
        if (used_cnt + decode_in.prvw_has_dests[i] > free_in.free_rdy_scnt)
            break;
        used_cnt += decode_in.prvw_has_dests[i];
        ++lim_cnt_free;
    end
    alloc_en_cnt = `MIN(lim_cnt_free, alloc_en_cnt);
    alloc_en_cnt = `MIN(alloc_rdy_scnt, alloc_en_cnt);
    
    decode_out.dispatch_en_cnt  = alloc_en_cnt;
    rob_out.alloc_en_cnt        = alloc_en_cnt;
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

logic [$clog2(`N):0] lim_cnt_btq;
always_comb begin
    rename_en_cnt = alloc_vld_scnt;

    lim_cnt_btq = 0;
    for (int unsigned i = 0, int used_cnt = 0; i < `N; ++i) begin
        if (used_cnt + rename_in[i].is_brch > btq_in.btq_rdy_scnt)
            break;
        used_cnt += rename_in[i].is_brch;
        ++lim_cnt_btq;
    end
    rename_en_cnt = `MIN(lim_cnt_btq, rename_en_cnt);

    lim_cnt_sq = 0;
    for (int unsigned i = 0, int used_cnt = 0; i < `N; ++i) begin
        if (used_cnt + rename_in[i].wr_mem > sq_in.sq_rdy_scnt)
            break;
        used_cnt += rename_in[i].wr_mem;
        ++lim_cnt_sq;
    end
    rename_en_cnt = `MIN(lim_cnt_sq, rename_en_cnt);

    lim_cnt_lq = 0;
    for (int unsigned i = 0, int used_cnt = 0; i < `N; ++i) begin
        if (used_cnt + rename_in[i].rd_mem > lq_in.lq_rdy_scnt)
            break;
        used_cnt += rename_in[i].rd_mem;
        ++lim_cnt_lq;
    end
    rename_en_cnt = `MIN(lim_cnt_lq, rename_en_cnt);

    rename_en_cnt = `MIN(rename_rdy_scnt, rename_en_cnt);
end

// handle btq output
logic [`N-1:0] is_brch;
logic [`N-1:0] wr_mem;
logic [`N-1:0] rd_mem;
always_comb begin
    foreach(rename_en[i])
        rename_en[i] = i < rename_en_cnt;

    foreach(is_brch[i])
        is_brch[i]  = rename_in[i].is_brch;
    foreach(wr_mem[i])
        wr_mem[i]   = rename_in[i].wr_mem;
    foreach(rd_mem[i])
        rd_mem[i]   = rename_in[i].rd_mem;

    sq_out.rename_en_cnt= $countones(rename_en & wr_mem);
    lq_out.rename_en_cnt= $countones(rename_en & rd_mem);
    btq_out.en_cnt      = $countones(rename_en & is_brch);
end

// handle map table output 
always_comb begin
    map_out = '0;
    map_out.en_cnt  = rename_en_cnt;

    for (int i = 0; i < rename_en_cnt; i++) begin
        //handling dest register
        map_out.ts[i]       = rename_in[i].t;
        map_out.dsts[i]     = rename_in[i].dest_reg_idx;
        //handling src tags
        map_out.src1s[i]    = rename_in[i].inst.r.rs1;
        map_out.src2s[i]    = rename_in[i].inst.r.rs2;
    end
end

RENAME_COMMIT_PKT [`N-1:0] tmp_alloc2rename;
logic [`N-1:0] rd_src1s;
logic [`N-1:0] rd_src2s;
logic [$clog2(`N):0] btq_wr_idx;
always_comb begin
    tmp_alloc2rename = '0;
    btq_wr_idx  = 0;
    btq_out.NPC = '0;

    btq_out.PC = '0;
    btq_out.bhr = '0;
    btq_out.pred = '0;
    btq_out.gshare_pred = '0;
    btq_out.corr_pred = '0;
    btq_out.correlated_bhr = '0;

    for (int i = 0; i < `N; ++i) begin
        tmp_alloc2rename[i].dat         = rename_in[i];

        tmp_alloc2rename[i].dat.t       = map_out.ts[i];
        tmp_alloc2rename[i].t_old       = map_in.ts_old[i];
        tmp_alloc2rename[i].dat.t1      = map_in.t1s[i];
        tmp_alloc2rename[i].dat.t2      = map_in.t2s[i];

        // actually need src tags?
        rd_src1s[i] = rename_in[i].opa_select == OPA_IS_RS1
            || rename_in[i].cond_branch;
        rd_src2s[i] = rename_in[i].opb_select == OPB_IS_RS2
            || rename_in[i].cond_branch
            || rename_in[i].wr_mem;
        tmp_alloc2rename[i].dat.t1_rdy  = !rd_src1s[i];
        tmp_alloc2rename[i].dat.t2_rdy  = !rd_src2s[i];

        if (rename_in[i].is_brch) begin
            tmp_alloc2rename[i].dat.btq_idx = btq_in.btq_idxs[btq_wr_idx];
            btq_out.NPC[btq_wr_idx] = rename_in[i].NPC;
            btq_out.PC[btq_wr_idx] =      rename_in[i].PC;

            btq_out.bhr[btq_wr_idx] = rename_in[i].bhr;
            btq_out.pred[btq_wr_idx] = rename_in[i].pred;

            btq_out.gshare_pred[btq_wr_idx] = rename_in[i].gshare_pred;
            btq_out.corr_pred[btq_wr_idx] = rename_in[i].corr_pred;
            btq_out.correlated_bhr[btq_wr_idx] = rename_in[i].correlated_bhr;
            ++btq_wr_idx;
        end
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

/* >> ==== 3. Commit Stage ==== >> */

logic [$clog2(`N):0] sq_wr_idx;
logic [$clog2(`N):0] lq_wr_idx;
// handle rs output 
always_comb begin
    commit_en_cnt   = `MIN(rename_vld_scnt, rs_in.rs_rdy_scnt);
    rs_out.d_en_cnt = commit_en_cnt;
    rs_out.d_dat    = '0;
    sq_wr_idx       = 0;
    lq_wr_idx       = 0;
    lq_out.rob_idx = '0; //handling latch prevention
    lq_out.sq_idx = '0;
    lq_out.inst_pc = '0;
    sq_out.rob_idx = '0;

    for (int i = 0; i < `N; i++) begin
        rs_out.d_dat[i] = commit_in[i].dat;
        rs_out.d_dat[i].rob_idx = rob_in.rob_idxs[i];
        for (int c = 0; c < `N; ++c) begin
            rs_out.d_dat[i].t1_rdy |= ctag_in.en[c] & (ctag_in.ts[c] == commit_in[i].dat.t1);
            rs_out.d_dat[i].t2_rdy |= ctag_in.en[c] & (ctag_in.ts[c] == commit_in[i].dat.t2);
        end
        rs_out.d_dat[i].t1_rdy |= cpl_lst[commit_in[i].dat.t1];
        rs_out.d_dat[i].t2_rdy |= cpl_lst[commit_in[i].dat.t2];

        if (commit_in[i].dat.wr_mem) begin
            rs_out.d_dat[i].sq_idx = sq_in.next_ids[sq_wr_idx];
            sq_out.rob_idx[sq_wr_idx] = rob_in.rob_idxs[i];
            ++sq_wr_idx;
        end

        if (commit_in[i].dat.rd_mem) begin
            // rs_out.d_dat[i].sq_idx = (sq_in.no_store_yet && (sq_wr_idx == 0)) ? `LSQ_SZ : (sq_in.last_used_sq_idx + sq_wr_idx) % `LSQ_SZ;
            // lq_out.sq_idx[lq_wr_idx] = (sq_in.no_store_yet && (sq_wr_idx == 0)) ? `LSQ_SZ : (sq_in.last_used_sq_idx + sq_wr_idx) % `LSQ_SZ;
            // $display("ASSIGNING: last_used: %0d, sq_wr_idx: %0d, no_store_yet: %b, assignment: %0d", sq_in.last_used_sq_idx, sq_wr_idx, sq_in.no_store_yet, rs_out.d_dat[i].sq_idx);
            
            if (sq_in.no_store_yet && (sq_wr_idx == 0)) begin
                lq_out.sq_idx[lq_wr_idx] = `LSQ_SZ;
                rs_out.d_dat[i].sq_idx = `LSQ_SZ;
            end
            else if (sq_wr_idx == 0) begin
                lq_out.sq_idx[lq_wr_idx] = sq_in.last_used_sq_idx;
                rs_out.d_dat[i].sq_idx = sq_in.last_used_sq_idx;
            end 
            else begin
                lq_out.sq_idx[lq_wr_idx] = sq_in.next_ids[sq_wr_idx-1];
                rs_out.d_dat[i].sq_idx = sq_in.next_ids[sq_wr_idx-1];
            end 
            lq_out.inst_pc[lq_wr_idx] = commit_in[i].dat.PC;
            rs_out.d_dat[i].lq_idx = lq_in.next_ids[lq_wr_idx];

            ++lq_wr_idx;
        end
    end

    // sq_out.sq_d_en_cnt = sq_wr_idx;
    // lq_out.lq_d_en_cnt = lq_wr_idx;
end


logic [$clog2(`N):0] sq_wr_cnt;
logic [$clog2(`N):0] lq_wr_cnt;
always_comb begin
    sq_wr_cnt = 0;
    lq_wr_cnt = 0;

    for (int i = 0; i < `N; i++) begin
        if (i >= commit_en_cnt) continue;
        
        if (commit_in[i].dat.wr_mem) begin
            ++sq_wr_cnt;
        end

        if (commit_in[i].dat.rd_mem) begin
            ++lq_wr_cnt;
        end
    end

    sq_out.sq_d_en_cnt = sq_wr_cnt;
    lq_out.lq_d_en_cnt = lq_wr_cnt;
end

// handle rob output 
always_comb begin
    rob_out.d_en_cnt = commit_en_cnt;

    for (int i = 0; i < `N; i++) begin
        //handling src tags
        rob_out.is_brch[i]  = commit_in[i].dat.is_brch;
        rob_out.wr_mem[i]   = commit_in[i].dat.wr_mem;
        rob_out.rd_mem[i]   = commit_in[i].dat.rd_mem;
        rob_out.tag[i]      = commit_in[i].dat.t;
        rob_out.t_old[i]    = commit_in[i].t_old;
        //handling dest register
        rob_out.dst[i]      = commit_in[i].dat.dest_reg_idx;

        rob_out.halt[i]     = commit_in[i].dat.halt;
        rob_out.illegal[i]  = commit_in[i].dat.illegal;
    end
end

always_ff @(posedge clock) begin
    
    if (reset || flush) begin
        cpl_lst <= '1;
    end else begin
        for (int i = 0; i < map_out.en_cnt; ++i) begin
            if (map_out.dsts[i] != `ZERO_REG)
                cpl_lst[map_out.ts[i]] <= 0;
        end
        for (int c = 0; c < `N; ++c) begin
            if (ctag_in.en[c])
                cpl_lst[ctag_in.ts[c]] <= 1;
        end
    end
end

`ifdef DEBUG
assign dbg = '{
    decode_in,
    decode_out,
    rs_in,
    rs_out,
    rob_in,
    rob_out,
    free_in,
    free_out,
    sq_in,
    sq_out,
    btq_in,
    btq_out,
    ctag_in,
    map_in,
    map_out
};
`endif

endmodule


