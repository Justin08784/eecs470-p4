`include "sys_defs.svh"

typedef struct packed {
    DWADDR          dw;
    logic[1:0][3:0] off;
    logic   [1:0]   fmsk;   // which words to fetch.
        /* Invariants:
        1. At least bit 0 (word 0) set
        2. Bits set contiguously from 0

        FUTURE: Invariant 2 may no longer hold if we detect when a branch in an
        early word targets into a later word *in the same cache line*,
        AND we allow storing them together in a single cache line. Then and all insns
        between the branch and target would have fmsk set to 0.
            Idea: if the branch target is in the same cache line as the
            branch (much more likely with larger cache lines), we may reuse
            the 14-bit tgt field in the FTB branch slot as a [$clog2(cache_line_sz)-1:0]
            in-line offset (possible with a carry bit for faster computation).
        */
    logic   [1:0]   is_end;
        /* Does word i *terminate* an FB?
        Both bits can be 1 when word0 ends FB-A and word1 ends FB-B (a 1-insn block). */
    
    MEM_BLOCK       blk;
    BRANCH_MD[1:0]  md;
} ICACHE_RESPONSE;

typedef struct packed {
    logic       is_tail;
    WADDR       PC;
    logic[3:0]  off;
    logic       pred;
    WADDR       pred_tgt;
    logic       always_take;
    FTB_MD1     md;

    logic       hit;
    logic       hit_slot;
    logic       slot_idx;
    logic[1:0]  in_ghr;
    // logic[GHR_LEN-1:0] hash; // gshare hash index
    GHR_IDX     ghr_base;
} BTQ_CAND;

// icache response queue
module irq #(
    parameter DEPTH=IRQ_SZ,
    type PTR=`IDX_TYPE(DEPTH)
) (
    input   clock,
    input   reset,
    input   flush,

    // write
    output  PTR [2:0]       wr_idxs_n,
    output  `CNT_TYPE(2)    rdy_scnt,
    input   `CNT_TYPE(2)    wen_cnt,
    input   pc_gen2ixq[1:0] wdat,

    // icache completions
    input   logic [1:0]     cen,
    input   PTR [1:0]       cidx,
    input   mem2fetch       cdat,

    // read
    output  `CNT_TYPE(2)    vld,
    input   `CNT_TYPE(2)    ren_cnt,
    output  ICACHE_RESPONSE [1:0]   rdat
);
    PTR [2:0]   rd_idxs_n;
    `CNT_TYPE(2)used_scnt;
    `CNT_TYPE(2)free_scnt;

    logic [DEPTH-1:0]           cpl;
    ICACHE_RESPONSE [DEPTH-1:0] state;

    ring_ctr #(
        .DEPTH(DEPTH),
        .RPORTS(2),
        .WPORTS(2),
        .FLUSH_MODE(FIFO_FLUSH_RESET)
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,

        .rd_en_cnt  (ren_cnt),
        .wr_en_cnt  (wen_cnt),

        .head       (),
        .tail       (),
        .rd_idxs_n,
        .wr_idxs_n,

        .used       (),
        .free       (),
        .used_scnt,
        .free_scnt
    );

    assign vld[0] = (0 < used_scnt) & cpl[rd_idxs_n[0]];
    assign vld[1] = (1 < used_scnt) & cpl[rd_idxs_n[1]] & vld[0];
    for (genvar i = 0; i < 2; ++i)
        assign rdat[i] = state[rd_idxs_n[i]];
    assign rdy_scnt = free_scnt;

    always_ff @(posedge clock) begin
        for (int i = 0; i < 2; ++i) begin
            int cur;
            if (!cen[i])
                continue;
            cur = cidx[i];

            cpl  [cur]      <= 1;
            state[cur].blk  <= cdat.data[i];
            state[cur].md   <= cdat.insn_md[i];
        end

        for (int i = 0; i < 2; ++i) begin
            int cur;
            if (i >= wen_cnt)
                continue;
            cur = wr_idxs_n[i];

            cpl  [cur]          <= 0;
            state[cur].dw       <=  wdat[i].dw;
            state[cur].off      <=  wdat[i].off;
            state[cur].fmsk     <=  wdat[i].fmsk;
            state[cur].is_end   <=  wdat[i].is_end;
        end

        if (flush)
            cpl <= '1;
    end


`ifdef DEBUG
    task print_irq;
        $display(">> IRQ");
        $display("vld: %b, rdy_scnt: %d", vld, rdy_scnt);
        $display("ren_cnt: %d, wen_cnt: %d", ren_cnt, wen_cnt);
        $display("rd[%d, %d, %d], wr[%d, %d, %d]",
            rd_idxs_n[0],
            rd_idxs_n[1],
            rd_idxs_n[2],
            wr_idxs_n[0],
            wr_idxs_n[1],
            wr_idxs_n[2]
        );
        for (int i = 0; i < IRQ_SZ; ++i) begin
            $display("irq[%d]: cpl: %b, dw: %d, off: [%d, %d], pc: (%d, %d), fmsk: %b, is_end: %b, blk: [%x, %x], md: [%b, %b]",
                i,
                cpl[i],
                state[i].dw,
                state[i].off[0],
                state[i].off[1],
                {state[i].dw, 1'b0},
                {state[i].dw, 1'b1},
                state[i].fmsk,
                state[i].is_end,
                state[i].blk.word_level[0],
                state[i].blk.word_level[1],
                state[i].md[0],
                state[i].md[1]
            );
        end
    endtask
`endif


endmodule


// combinational align
module align (
    input   clock,
    input   reset,
    input   flush,
    // input   `CNT_TYPE(4)    expander_in_vld_scnt, // do we even need this?
    input   BTQ_CAND[3:0]   expander_in_dat,
    output  `CNT_TYPE(4)    expander_out_ren_cnt,

    // read (icache response queue)
    input   logic[1:0]      irq_in_vld,
    input   ICACHE_RESPONSE[1:0] irq_in_dat,
    output  `CNT_TYPE(2)    irq_out_ren_cnt,

    // write (branch target queue)
    input   btq2fetch       btq_in,
    output  fetch2btq       btq_out,

    input   `CNT_TYPE(4)    ibuf_in_rdy_scnt,
    output  `CNT_TYPE(4)    ibuf_out_wen_cnt,
    output  IF_ID_PKT[3:0]  ibuf_out_dat

);
    typedef struct packed {
        BRANCH_MD   md;
        IF_ID_PKT   f_dat;
    } ALIGN1_RES;
    localparam W_PER_DW = 2;
    localparam NUM_DW   = 2;
    localparam NUM_FTQ  = 2;
    localparam NUM_W    = NUM_DW*W_PER_DW;

    initial begin
        /* impl is hardcoded/tuned to the following params */
        assert (NUM_DW == 2)    else $fatal;
        assert (NUM_FTQ == 2)   else $fatal;
    end

    // align 1
    /*
    raw: not aligned
    bal: block aligned (compaction WITHIN blocks)
    wal: block AND word aligned (compaction across entire array) */

    logic [NUM_W-1:0][3:0] raw_off;
    WADDR [NUM_W-1:0] raw_pc;
    BRANCH_MD [NUM_W-1:0] raw_md;
    struct packed {
        logic [NUM_W-1:0] fmsk, indw_last, irq_vld, irq_top_vld, irq_bot_vld;
        ALIGN1_RES[NUM_W-1:0] dat;
    } raw, bal, wal;
    
    struct packed {
        logic   [1:0] blk;  // compact inside block i?
        logic   mid;        // cross from b1 into b0?
    } shl; // shift lefts

    generate
    logic [NUM_DW-1:0][W_PER_DW-1:0] before_indw_last;

       // ^^ prefix mechanism hardcoded for N=2
    assign raw.indw_last = raw.fmsk & ~before_indw_last;

    for (genvar b = 0; b < NUM_DW; ++b) begin
        ICACHE_RESPONSE cur;
        assign cur  = irq_in_dat[b];

        assign before_indw_last [b][W_PER_DW-1] = 0;
        for (genvar i = 0; i < W_PER_DW-1; ++i)
            assign before_indw_last[b][W_PER_DW-1 - (i+1)] =
                before_indw_last[b][W_PER_DW-1 - i] | cur.fmsk[W_PER_DW-1 - i];

        for (genvar w = 0; w < W_PER_DW; ++w) begin
            localparam flat_idx = W_PER_DW*b+w;

            assign raw_off  [flat_idx]  = cur.off[w];
            assign raw_pc   [flat_idx]  = {cur.dw, w[0]};
            assign raw_md   [flat_idx]  = cur.md[w];
            assign raw.fmsk [flat_idx]  = cur.fmsk[w];
            assign raw.irq_vld[flat_idx]= irq_in_vld[b];
            assign raw.dat[flat_idx]    = '{
                md      : cur.md[w],
                f_dat   : '{
                    PC      : raw_pc[flat_idx],
                    inst    : cur.blk.word_level[w],
                    btq_idx : 'x,// TODO: fill in align 2
                    // btq_idx : btq_in.btq_idxs_n[brch_prefix_cnt[flat_idx]],
                    ras_snap: '0 // FIXME
                }
            };
        end
    end
    assign raw.irq_top_vld = {raw.irq_vld[3:2], 2'b0};
    assign raw.irq_bot_vld = {2'b0, raw.irq_vld[1:0]};
    endgenerate

    assign shl = '{
        blk : {raw.irq_vld[2] & ~raw.fmsk[2], raw.irq_vld[0] & ~raw.fmsk[0]},
        mid : |(raw.irq_vld[1:0] & ~raw.fmsk[1:0])
            /* since each cache line contains at least 1 valid word,
            the cross (mid) shift is at most 1 
            
            The irq_vld mask guards access to potentially garbage values. */
    };

    for (genvar b = 0; b < NUM_DW; ++b) begin : block_align
        localparam lo = W_PER_DW*b;
        localparam hi = W_PER_DW*(b+1) - 1;

        // full shift controls (cannot permit duplicates)
        assign bal.fmsk     [hi:lo] = raw.fmsk      [hi:lo] >> shl.blk[b];
        assign bal.irq_vld  [hi:lo] = raw.irq_vld   [hi:lo] >> shl.blk[b];
        assign bal.indw_last[hi:lo] = raw.indw_last [hi:lo] >> shl.blk[b];
        assign bal.irq_top_vld[hi:lo]   = raw.irq_top_vld[hi:lo] >> shl.blk[b];
        assign bal.irq_bot_vld[hi:lo]   = raw.irq_bot_vld[hi:lo] >> shl.blk[b];

        // bleed/copy shift data (duplicates fine–– guarded by controls)
        assign bal.dat      [lo]    = shl.blk[b] ? raw.dat[hi] : raw.dat[lo];
        assign bal.dat      [hi]    = raw.dat[hi];
    end

    // word_align
    assign wal.fmsk     [0]     = bal.fmsk      [0];
    assign wal.irq_vld  [0]     = bal.irq_vld   [0];
    assign wal.indw_last[0]     = bal.indw_last [0];
    assign wal.irq_top_vld[0]   = bal.irq_top_vld[0];
    assign wal.irq_bot_vld[0]   = bal.irq_bot_vld[0];

    assign wal.fmsk     [3:1]   = bal.fmsk      [3:1]   >> shl.mid;
    assign wal.irq_vld  [3:1]   = bal.irq_vld   [3:1]   >> shl.mid;
    assign wal.indw_last[3:1]   = bal.indw_last [3:1]   >> shl.mid;
    assign wal.irq_top_vld[3:1] = bal.irq_top_vld[3:1]  >> shl.mid;
    assign wal.irq_bot_vld[3:1] = bal.irq_bot_vld[3:1]  >> shl.mid;

    assign wal.dat      [0]     = bal.dat[0];
    assign wal.dat      [3]     = bal.dat[3];
    assign wal.dat      [1]     = shl.mid ? bal.dat[2] : bal.dat[1];
    assign wal.dat      [2]     = shl.mid ? bal.dat[3] : bal.dat[2];

    `CNT_TYPE(4)    align1_res_free_scnt;
    `CNT_TYPE(4)    align1_res_wen_cnt;
    ALIGN1_RES[3:0] align1_res_wdat;

    logic [NUM_W-1:0] wal_vld, align1_res_rdy, wal_en, bal_en, raw_en;
    assign wal_vld = wal.irq_vld & wal.fmsk & wal.indw_last;
    for (genvar w = 0; w < NUM_W; ++w)
        assign align1_res_rdy[w] = w < align1_res_free_scnt;

    logic top_en, bot_en;
    logic [NUM_W-1:0] top_en_msk, bot_en_msk;
    assign top_en = ~|(wal.irq_top_vld & ~align1_res_rdy);
    assign bot_en = ~|(wal.irq_bot_vld & ~align1_res_rdy);
    assign top_en_msk = {4{top_en}} & wal.irq_top_vld;
    assign bot_en_msk = {4{bot_en}} & wal.irq_bot_vld;

    assign wal_en = top_en_msk | bot_en_msk;
    assign bal_en = {wal_en[3:1] << shl.mid,    wal_en[0]};
    assign raw_en = {bal_en[3:2] << shl.blk[1], bal_en[1:0] << shl.blk[0]};

    assign align1_res_wen_cnt   = $countones(wal_en & wal.fmsk);
    assign align1_res_wdat      = wal.dat;
    assign irq_out_ren_cnt      = $countones(raw_en & raw.indw_last);

    `CNT_TYPE(4)    a1_a2_used_scnt;
    `CNT_TYPE(4)    a2_a1_ren_cnt;
    ALIGN1_RES[3:0] a1_a2_rdat;

    fifo #(
        .DEPTH(8),
        .WIDTH($bits(ALIGN1_RES)),
        .NUM_RPORTS(4),
        .NUM_WPORTS(4),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(72)
    ) align1_res (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),

        // >> unused inputs
        .flush_snap ('0),
        .clmsk      ('0),
        .wr_bmask   ('0),
        // << unused inputs

        .wr_en_cnt  (align1_res_wen_cnt),
        .wr_data    (align1_res_wdat),
        .rd_en_cnt  (a2_a1_ren_cnt),
        .rd_data    (a1_a2_rdat),
        .free_scnt  (align1_res_free_scnt),
        .used_scnt  (a1_a2_used_scnt)
    );

    // fifo_barrel #(
    //     .DEPTH(8),
    //     .WIDTH($bits(ALIGN1_RES)),
    //     .RPORTS(4),
    //     .WPORTS(4)
    // ) align1_res (
    //     .clock      (clock),
    //     .reset      (reset),
    //     .flush      (flush),

    //     .wvld_cnt   (align1_res_wen_cnt),
    //     .wdat       (align1_res_wdat),
    //     .rrdy_cnt   (a2_a1_ren_cnt),
    //     .rdat       (a1_a2_rdat),
    //     .wrdy_cnt   (align1_res_free_scnt),
    //     .rvld_cnt   (a1_a2_used_scnt)
    // );

    // align 2

    logic [NUM_W-1:0] a1_a2_vld, a1_a2_brch;
    for (genvar w = 0; w < NUM_W; ++w) begin
        assign a1_a2_vld[w] = w < a1_a2_used_scnt;
        assign a1_a2_brch[w]= a1_a2_rdat[w].md.brch;
    end

`ifdef FORMAL
    BRANCH_MD [NUM_W-1:0] uftb_md;
    for (genvar w = 0; w < NUM_W; ++w) begin
        FTB_MD1 uftb_md1;
        assign uftb_md1 = btq_wr[w].md;
        assign uftb_md[w] = '{
            brch:   btq_wr[w].hit & btq_wr[w].hit_slot,
            cond:   uftb_md1.cond,
            call:   uftb_md1.call,
            ret :   uftb_md1.ret,
            jalr:   uftb_md1.jalr
        };
    end
`endif
    BTQ_CAND[NUM_W-1:0] btq_wr, btq_wr_comp;

    `CNT_TYPE(NUM_W) brch_lim_cnt;
    logic [NUM_W:0][`CNT_SIZE(N)-1:0] brch_prefix_cnt;
    compactor #(
        .REQW(NUM_W),
        .GNTW(N)
    ) comp_brch (
        .req        (a1_a2_vld & a1_a2_brch),
        .lim_cnt    (btq_in.rdy_scnt),
        .prefix_cnt (brch_prefix_cnt),
        .gnt_cnt    (brch_lim_cnt)
    );
    always_comb begin
        for (int w = 0; w < NUM_W; ++w) begin
            btq_wr[w]   = expander_in_dat[w];
            btq_wr[w].PC= a1_a2_rdat[w].f_dat.PC;
            btq_wr[w].md= a1_a2_rdat[w].md;
        end
    end
    always_comb begin
        btq_wr_comp = '0;
        for (int w = 0; w < NUM_W; ++w)
            btq_wr_comp[brch_prefix_cnt[w]] = btq_wr[w];
    end

    for (genvar w = 0; w < N; ++w) begin
        assign btq_out.is_tail  [w] = btq_wr_comp[w].is_tail;
        assign btq_out.PC       [w] = btq_wr_comp[w].PC;
        assign btq_out.off      [w] = btq_wr_comp[w].off;
        assign btq_out.pred     [w] = btq_wr_comp[w].pred;
        assign btq_out.pred_tgt [w] = btq_wr_comp[w].pred_tgt;
        assign btq_out.always_take[w]=btq_wr_comp[w].always_take;
        assign btq_out.md       [w] = btq_wr_comp[w].md;
        assign btq_out.hit      [w] = btq_wr_comp[w].hit;
        assign btq_out.hit_slot [w] = btq_wr_comp[w].hit_slot;
        assign btq_out.slot_idx [w] = btq_wr_comp[w].slot_idx;
        assign btq_out.in_ghr   [w] = btq_wr_comp[w].in_ghr;
        // assign btq_out.hash     [w] = btq_wr_comp.hash; // FIXME
        assign btq_out.ghr_base [w] = btq_wr_comp[w].ghr_base; // FIXME

    end

    always_comb begin
        for (int w = 0; w < NUM_W; ++w) begin
            ibuf_out_dat[w] = a1_a2_rdat[w].f_dat;
            ibuf_out_dat[w].btq_idx = btq_in.btq_idxs_n[brch_prefix_cnt[w]];
        end
    end
    assign a2_a1_ren_cnt        = `MIN(`MIN(a1_a2_used_scnt, ibuf_in_rdy_scnt), brch_lim_cnt);
    assign expander_out_ren_cnt = a2_a1_ren_cnt;
    assign ibuf_out_wen_cnt     = a2_a1_ren_cnt;
    assign btq_out.wen_cnt      = brch_prefix_cnt[a2_a1_ren_cnt];


`ifdef FORMAL
    /* uftb_no_false_positive:
    - 1. if not fetching, don't care
    - 2. if icache predecode asserts "is not branch", then uftb must not assert "is branch"
    - 2. if both icache predecode and uftb asserts "is branch", then all the branch metadata
    fields should match exactly

    We expect this property to hold because the uftb does not skimp bits on its tag. However,
    if we DO skimp bits, then some non-branch insns may be misidentified as branches,
    and potentially cause the ghr to halt (BPU would shift predictions for non-branches
    into the GHR, and they would never be resolved because non-branches do not get
    allocated to the BTQ).
    */
    logic [NUM_W-1:0] uftb_no_false_positive;
    always_comb begin
        for (int w = 0; w < NUM_W; ++w) begin
            logic vld;
            vld = w < a1_a2_used_scnt;

            if (~vld)
                uftb_no_false_positive[w] = 1;
            else if (vld & ~a1_a2_rdat[w].md.brch)
                uftb_no_false_positive[w] = ~uftb_md[w].brch;
            else if (vld & a1_a2_rdat[w].md.brch & ~uftb_md[w].brch)
                uftb_no_false_positive[w] = 1;
            else if (vld & a1_a2_rdat[w].md.brch & uftb_md[w].brch) begin
                uftb_no_false_positive[w] =
                    (a1_a2_rdat[w].md.cond == uftb_md[w].cond)
                &   (
                        (~a1_a2_rdat[w].md.cond)
                    |   (
                            (a1_a2_rdat[w].md.call == uftb_md[w].call)
                        &   (a1_a2_rdat[w].md.ret  == uftb_md[w].ret)
                        &   (a1_a2_rdat[w].md.jalr == uftb_md[w].jalr)
                        )
                    );
            end
        end
    end

    task error_uftb_no_false_positive;
        $display("a1_a2_used_scnt: %d, uftb_no_false_positive: %b", a1_a2_used_scnt, uftb_no_false_positive);
        for (int w = 0; w < NUM_W; ++w)
            $display("raw_pc: %d, aw: {brch: %b, cond: %b, call: %b, ret: %b, jalr: %b} uftb_md: {brch: %b, cond: %b, call: %b, ret: %b, jalr: %b}",
                a1_a2_rdat[w].f_dat.PC,
                a1_a2_rdat[w].md.brch,
                a1_a2_rdat[w].md.cond,
                a1_a2_rdat[w].md.call,
                a1_a2_rdat[w].md.ret,
                a1_a2_rdat[w].md.jalr,

                uftb_md[w].brch,
                uftb_md[w].cond,
                uftb_md[w].call,
                uftb_md[w].ret,
                uftb_md[w].jalr
            );
        $fatal;
    endtask

    always_ff @(posedge clock) begin
        assert(reset | &uftb_no_false_positive) else error_uftb_no_false_positive;
    end

    // property p_uftb_no_false_positive;
    //     @(posedge clock)
    //         disable iff (reset)
    //         &uftb_no_false_positive;
    // endproperty

    // Uftb_No_False_Positive: assert property(p_uftb_no_false_positive)
    //     else error_uftb_no_false_positive();
`endif

`ifdef DEBUG
    task print_align;
        // $display("ghr_base_n1: [%d, %d]", rrb_in_dat[0].ghr_base_n1, rrb_in_dat[1].ghr_base_n1);
        // for (int w = 0; w < NUM_W; ++w) begin
        //     FTQ_ENTRY r;
        //     logic vgt0, vgt1;

        //     r = rrb_in_dat[rrb_prefix[w]];
        //     vgt0= r.slot[0].in_ghr && r.slot[0].vld && (raw_off[w] > r.slot[0].off);
        //     vgt1= r.slot[1].in_ghr && r.slot[1].vld && (raw_off[w] > r.slot[1].off);

        //     $display("base: %d, vgt: [%b %b], ma: %d",
        //         r.ghr_base_n1,
        //         vgt0,
        //         vgt1,
        //         r.ghr_base_n1 - (2'(vgt0) + 2'(vgt1))
        //     );

        // end
        $display("-- ALIGN 1 --");
        $display("irq_in_vld: %b, raw_pc [%d, %d], raw.irq_vld: %b",
            irq_in_vld,
            raw_pc[0],
            raw_pc[1],
            raw.irq_vld
        );
        $display("wal.irq_{top_vld: %b, bot_vld: %b}",
            wal.irq_top_vld,
            wal.irq_bot_vld
        );
        $display("raw.fmsk: %b, raw.indw_last: %b", raw.fmsk, raw.indw_last);
        $display("wal.fmsk: %b, wal.indw_last: %b", wal.fmsk, wal.indw_last);
        $display("shl.blk[0]: %b, shl.blk[1]: %b, shl.mid: %b",
            shl.blk[0],
            shl.blk[1],
            shl.mid
        );
        for (int w = 0; w < 4; ++w) begin
            if (w < align1_res_wen_cnt)
                $display("align1_res[%1d]: md = %b, f_dat = {PC = %4d, inst = %x, btq_idx = %x}",
                    w,
                    align1_res_wdat[w].md,
                    align1_res_wdat[w].f_dat.PC,
                    align1_res_wdat[w].f_dat.inst,
                    align1_res_wdat[w].f_dat.btq_idx
                );
            else
                $display("align1_res[%1d]:", w);
        end
        $display("align1_res_wen_cnt: %1d, irq_out_ren_cnt: %1d", align1_res_wen_cnt, irq_out_ren_cnt);

        $display("-- ALIGN 2 --");

        $display("a2_a1_ren_cnt: %d, btq_out.wen_cnt: %d", a2_a1_ren_cnt, btq_out.wen_cnt);
        // $display("::rrb_ren_cnt: %d", rrb_out_ren_cnt);
        // for (int i = 0; i < 4; ++i) begin
        //     $display("::irq_in[%d]: pc: %d, inst: %x",
        //         i,
        //         raw_pc[i],
        //         irq_in_dat[i/2].blk.word_level[i%2]
        //     );

        // end

        // $display("wal.indw_last: %0d, %0d, %0d, %0d",
        //     $countones(wal.indw_last[0:0]),
        //     $countones(wal.indw_last[1:0]),
        //     $countones(wal.indw_last[2:0]),
        //     $countones(wal.indw_last[3:0])
        // );

        // $display("req_res.rd_irq: %0d, %0d, %0d, %0d",
        //     ctl.req_res[0].rd_irq,
        //     ctl.req_res[1].rd_irq,
        //     ctl.req_res[2].rd_irq,
        //     ctl.req_res[3].rd_irq
        // );

        for (int i = 0; i < 4; ++i) begin
            $display("::f_dat[%d]: pc: %4d, inst: %x",
                i,
                ibuf_out_dat[i].PC,
                ibuf_out_dat[i].inst
            );
            // $display("  req_res: ibuf: %b, btq: %b, rrb: %b, irq: %b",
            //     ctl.req_res[i].wr_ibuf,
            //     ctl.req_res[i].wr_btq,
            //     ctl.req_res[i].rd_rrb,
            //     ctl.req_res[i].rd_irq
            // );
            // $display("  ctl.sat: ibuf: %b, btq: %b, rrb: %b, irq: %b",
            //     ctl.sat[i].wr_ibuf,
            //     ctl.sat[i].wr_btq,
            //     ctl.sat[i].rd_rrb,
            //     ctl.sat[i].rd_irq
            // );
        end
    endtask
`endif

endmodule


// decoupled fetch engine
module dcf (
    input   clock,
    input   reset,
    input   execute2complete_bru cbru_in,
    // input   WADDR flush_PC,
        /*
        WRONG >> 
            FIXME: this should/would be an FB base...?
        <<
        If branch was mispred NT-resolved T, then flush_PC indeed will be an fb_base.
        However, if branch was mispred T-resolved NT, then flush_PC may NOT be an
        fb_base–– instead flush_PC is more likely to be a nonzero offset INO the FB.
        */

    input   bpu2fetch   bpu_in,
    output  fetch2bpu   bpu_out,

    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   btq2fetch   btq_in,
    output  fetch2btq   btq_out,

    input   rename2snap_bus snap_in, // unused

    output  fetch2mem   mem_out,
    input   mem2fetch   mem_in

);
    logic flush;
    assign flush = cbru_in.flush;

    pc_gen2ixq [1:0]pc_gen2ixq_dat;
    `CNT_TYPE(2)    pc_gen2ixq_wen_cnt;
    `CNT_TYPE(2)    ixq2pc_gen_rdy_scnt;

    FTQ_ENTRY [1:0] pc_gen2rrb_dat;
    `CNT_TYPE(2)    pc_gen2rrb_wen_cnt;
    `CNT_TYPE(2)    rrb2pc_gen_rdy_scnt;

    pc_gen pc_gen0 (
        .clock,
        .reset,

        .flush,
        .flush_fb_base      (cbru_in.flush_fb_base),
        .flush_fb_off       (cbru_in.flush_fb_off),

        .ftq_in_vld_scnt    (bpu_in.vld_scnt),
        .ftq_in_dat         (bpu_in.dat),
        .ftq_out_ren_cnt    (bpu_out.ren_cnt),

        .ixq_in_rdy_scnt    (ixq2pc_gen_rdy_scnt),
        .ixq_out_wen_cnt    (pc_gen2ixq_wen_cnt),
        .ixq_out_dat        (pc_gen2ixq_dat),

        .rrb_in_rdy_scnt    (rrb2pc_gen_rdy_scnt),
        .rrb_out_wen_cnt    (pc_gen2rrb_wen_cnt),
        .rrb_out_dat        (pc_gen2rrb_dat)
    );

    // ""iqq""
    logic [2:0][`IDX_SIZE(IRQ_SZ)-1:0] irq_wr_idxs_n;
    struct packed {
        logic   [1:0]   vld;
        DWADDR  [1:0]   dw;
        logic   [1:0][`IDX_SIZE(IRQ_SZ)-1:0] irq_idx;
    } iqq, iqq_n;

    generate
    for (genvar i = 0; i < 2; ++i) begin
        assign iqq_n.vld    [i] = i < pc_gen2ixq_wen_cnt;

        assign iqq_n.dw     [i] = pc_gen2ixq_dat[i].dw;
        assign iqq_n.irq_idx[i] = irq_wr_idxs_n[i];
    end
    endgenerate

    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("iqq!");
    //         for (int i = 0; i < 2; ++i)
    //             $display("iqq[%d]: vld: %b, dw: %d, irq_idx: %d",
    //                 i,
    //                 iqq.vld[i],
    //                 iqq.dw[i],
    //                 iqq.irq_idx[i]
    //             );
    //     end
    // end

    struct packed {
        logic   [1:0]   vld;
        logic   [1:0][`IDX_SIZE(IRQ_SZ)-1:0] irq_idx;
        mem2fetch   mem_dat;
    } idat, idat_n;

    generate
    // assign mem_out.PCdws = iqq.dw;
    for (genvar i = 0; i < 2; ++i) begin
        assign mem_out.PCdws [i] = iqq.dw[i];
        assign idat_n.vld    [i] = iqq.vld[i];
        assign idat_n.irq_idx[i] = iqq.irq_idx[i];
    end
    assign idat_n.mem_dat = mem_in;
    endgenerate

    ICACHE_RESPONSE[1:0]irq2align_dat;
    logic[1:0]      irq2align_vld;
    `CNT_TYPE(2)    align2irq_ren_cnt;

    irq irq0 (
        .clock,
        .reset,
        .flush,

        .wr_idxs_n  (irq_wr_idxs_n),
        .rdy_scnt   (ixq2pc_gen_rdy_scnt),  // TODO: change irq when has backpressure
        .wen_cnt    (pc_gen2ixq_wen_cnt),
        .wdat       (pc_gen2ixq_dat),

        .cen        (idat.vld),
        .cidx       (idat.irq_idx),
        .cdat       (idat.mem_dat),

        .vld        (irq2align_vld),
        .ren_cnt    (align2irq_ren_cnt),
        .rdat       (irq2align_dat)
    );

    FTQ_ENTRY[1:0]  rrb2align_dat;
    `CNT_TYPE(2)    align2rrb_ren_cnt;

    `CNT_TYPE(2)    expander2rrb_ren_cnt;
    `CNT_TYPE(2)    rrb2expander_used_scnt;
    FTQ_ENTRY[1:0]  rrb2expander_dat;

    fifo #(
        .DEPTH(IRQ_SZ),
        .WIDTH($bits(FTQ_ENTRY)),
        .NUM_RPORTS(2),
        .NUM_WPORTS(2),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(72)
    ) rrb (
        .clock,
        .reset,
        .flush,

        // >> unused inputs
        .flush_snap ('0),
        .clmsk      ('0),
        .wr_bmask   ('0),
        // << unused inputs

        .wr_en_cnt  (pc_gen2rrb_wen_cnt),
        .wr_data    (pc_gen2rrb_dat),
        .rd_en_cnt  (expander2rrb_ren_cnt),
        .rd_data    (rrb2expander_dat),
        .free_scnt  (rrb2pc_gen_rdy_scnt),
        .used_scnt  (rrb2expander_used_scnt)
    );

    localparam NUM_FTQ  = 2;
    localparam NUM_W    = 4;
    typedef `IDX_TYPE(MAX_FB_SPAN) FB_OFF;
    struct packed {
        FB_OFF  off;
        WADDR   base;
    } cur; // cursor

    WADDR[NUM_FTQ:0]                base_n; // index: (ftq).
    FB_OFF[NUM_FTQ-1:0][NUM_W:0]    off_n;  // index: (ftq, word)
    logic[NUM_FTQ-1:0][NUM_W:0]     novf;   // index: (ftq, word) def. novf[e][w] := compute of off_n[e][w] does "not overflow (novf)" FB_OFF
    logic[NUM_FTQ-1:0][NUM_W-1:0]   vld;    // index: (ftq, word)
    logic[NUM_FTQ-1:0][NUM_W-1:0]   is_end; // index: (ftq, word)
    logic[NUM_FTQ-1:0][NUM_W:0]     after_end;
    assign base_n[0] = cur.base;
    assign base_n[1] = rrb2expander_dat[0].base_n;
    assign base_n[2] = rrb2expander_dat[1].base_n;

    assign off_n[0][0] = cur.off;
    assign off_n[1][0] = 0;
    assign novf[0][0]  = 1'b1;
    assign novf[1]     = '1;
    localparam FB_OFF MAX_FB_OFF = '1;
    for (genvar w = 1; w <= NUM_W; ++w) begin
        assign off_n[0][w] = cur.off + `UCAST_FIT(w);
        assign off_n[1][w] = w;
        assign novf[0][w]  = cur.off <= (MAX_FB_OFF - w);
    end
    initial begin
        assert(NUM_W <= MAX_FB_OFF) else $fatal;
        /* This ensures:
        - novf[1][w] is true for all 0≤w≤NUM_W
        - FB_OFF - w (used to compute novf[0][w]) does not underflow for all 0≤w≤NUM_W
        */
    end

    FB_OFF words_left_m1; // words left minus 1, clamped at 4 e.g. 0 for 1 left (ftq 0 only)
    assign words_left_m1 = `MIN(4, rrb2expander_dat[0].off - cur.off);

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        logic ftq_entry_vld;
        assign ftq_entry_vld = e < rrb2expander_used_scnt;

        for (genvar w = 0; w < NUM_W; ++w) begin
            assign vld[e][w]    = ftq_entry_vld & novf[e][w] & (off_n[e][w] <= rrb2expander_dat[e].off);
            assign is_end[e][w] = rrb2expander_dat[e].off == off_n[e][w];
        end
        assign after_end[e] = (after_end[e] | is_end[e]) << 1;
    end

    BTQ_CAND[NUM_FTQ-1:0][NUM_W-1:0] raw_cands;
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar w = 0; w < 4; ++w) begin
            FTQ_ENTRY r;
            logic ve0, ve1;
            logic vgt0, vgt1;

            assign r    = rrb2expander_dat[e];
            assign ve0  = r.slot[0].vld && (r.slot[0].off == off_n[e][w]);

            assign ve1  = r.slot[1].vld && (r.slot[1].off == off_n[e][w]);
            assign vgt0 = r.in_ghr[0] && r.slot[0].vld && (off_n[e][w] > r.slot[0].off);
            assign vgt1 = r.in_ghr[1] && r.slot[1].vld && (off_n[e][w] > r.slot[1].off);

            assign raw_cands[e][w] = '{
                is_tail     : (r.pred_idx == 1) && is_end[e][w],
                    /* FIXME (unsure): Probably not necessary to check for "off_geq_tail",
                    i.e. (r.pred_idx == 1) && (off_n[i] >= r.off), because branches after (>)
                    the tail slot would not even be in the same fetch block? */
                PC          : 'x,   // TODO: fill by aligner
                off         : off_n[e][w],
                pred        : !r.ft && is_end[e][w],
                pred_tgt    : r.base_n,
                always_take : !r.ft && is_end[e][w] ? r.always_take : 0,
`ifdef FORMAL
                md          : '{
                    // brch:   r.hit & (ve0 | ve1),
                    cond:   ve0 | (ve1 & r.md.cond),
                    call:   r.md.call,
                    ret :   r.md.ret,
                    jalr:   r.md.jalr
                },
`else
                md          : 'x,   // TODO: fill by aligner
`endif
                    // TODO: fix RAS if pred ret but not ret (likewise for call)

                hit         : r.hit,
                hit_slot    : ve0 || ve1,
                slot_idx    : ve1,
                in_ghr      : r.in_ghr,
                // assign btq_wr_cand.hash        : r.hash, // FIXME
                // assign btq_wr_cand.ghr_base    : r.ghr_base_n1 - (2'(vgt0) + 2'(vgt1)), // FIXME
                ghr_base    : r.ghr_base_n1 - (vgt0 + vgt1) // FIXME

                // i, i-1, i-2
                // 0,  1,  2

                // vld0, gt0, vld1,  gt1   -> 2
                // vld0, gt0, vld1, !gt1   -> 1
                // vld0, gt0, !vld1, gt1   -> 1
                // vld0, gt0, !vld1, !gt1  -> 1

                // vld0, !gt0, vld1,  gt1  -> 0 // impossible
                // vld0, !gt0, vld1, !gt1  -> 0
                // vld0, !gt0,!vld1, gt1   -> 0
                // vld0, !gt0,!vld1, !gt1  -> 0

                // !vld0, gt0, vld1,  gt1  -> 1
                // !vld0, gt0, vld1, !gt1  -> 0
                // !vld0, gt0,!vld1, gt1   -> 0
                // !vld0, gt0,!vld1, !gt1  -> 0

                // !vld0,!gt0, vld1,  gt1  -> 1
                // !vld0,!gt0, vld1, !gt1  -> 0
                // !vld0,!gt0,!vld1, gt1   -> 0
                // !vld0,!gt0,!vld1, !gt1  -> 0

            };

        end
    end

    logic[NUM_W-1:0]    vld_comp; // compacted
    logic[NUM_W-1:0]    is_end_comp;
    BTQ_CAND[NUM_W-1:0] cands_comp;
    logic[NUM_W-1:0]    sel_bot4;
    logic[NUM_W:0]      sel_bot5;
    FB_OFF[NUM_W:0]     off_n_comp;
    logic[NUM_W:0]      after_end_comp;
    assign sel_bot4 = ~( 4'b1110    << words_left_m1);
    assign sel_bot5 = ~(5'b11110    << words_left_m1);

    BTQ_CAND[NUM_W-1:0] sel_bot4_btq_cand_msk;
    FB_OFF[NUM_W:0]     sel_bot5_off_n_msk;
    for (genvar w = 0; w < NUM_W; ++w)
        assign sel_bot4_btq_cand_msk[w] = {$bits(BTQ_CAND){sel_bot4[w]}};
    for (genvar w = 0; w <= NUM_W; ++w)
        assign sel_bot5_off_n_msk[w] = {$bits(FB_OFF){sel_bot5[w]}};

    logic[4:0][$clog2(4*$bits(BTQ_CAND)+1)-1:0] btq_cand_shift_rom;
    logic[4:0][$clog2(4*$bits(FB_OFF)+1)-1:0]   fb_off_shift_rom;
    for (genvar s = 0; s <= 4; ++s) begin
        assign btq_cand_shift_rom[s]= s * $bits(BTQ_CAND);
        assign fb_off_shift_rom[s]  = s * $bits(FB_OFF);
    end

    assign vld_comp     = ({vld   [1][2:0], 1'b0} << words_left_m1) | vld[0];
    assign is_end_comp  = ({is_end[1][2:0], 1'b0} << words_left_m1) | is_end[0];
    assign cands_comp   =
        // ({raw_cands[1][2:0], {$bits(BTQ_CAND){1'b0}}}   << (words_left_m1*$bits(BTQ_CAND)))
        ({raw_cands[1][2:0], {$bits(BTQ_CAND){1'b0}}}   << btq_cand_shift_rom[words_left_m1])
    |   (raw_cands[0]   & sel_bot4_btq_cand_msk);
    assign off_n_comp   =
        // ({off_n[1][3:0], {$bits(FB_OFF){1'b0}}}         << (words_left_m1*$bits(FB_OFF)))
        ({off_n[1][3:0], {$bits(FB_OFF){1'b0}}}         << fb_off_shift_rom[words_left_m1])
    |   (off_n[0]       & sel_bot5_off_n_msk);
    assign after_end_comp = ({after_end[1][3:0], 1'b0}  << words_left_m1)
    |   (after_end[0]   & sel_bot5);

    `CNT_TYPE(4) en_cnt, free_scnt;
    logic [NUM_W-1:0] free, en_comp;
    for (genvar w = 0; w < NUM_W; ++w)
        assign free[w] = w < free_scnt;
    assign en_comp  = vld_comp & free;
    assign en_cnt   = $countones(en_comp);

    logic [NUM_W-1:0] en_end_comp;
    assign en_end_comp = en_comp & is_end_comp;
    assign expander2rrb_ren_cnt = $countones(en_end_comp);

`ifdef DEBUG
    task print_expander;
        $display("-- expander --");
        for (int e = 0; e < 2; ++e)
            if (e < rrb2expander_used_scnt)
                $display("fb[%1d]: base_n = %4d, off = %2d", e, rrb2expander_dat[e].base_n, rrb2expander_dat[e].off);
            else
                $display("fb[%1d]:", e);
        $display("cur: base = %x, off: %1d", cur.base, cur.off);
        $display("words_left_m1: %2d", words_left_m1);
        $display("sel_bot4:  %4b", sel_bot4);
        $display("sel_bot5: %5b", sel_bot5);

        $display("vld: [%b, %b]", vld[0], vld[1]);

        $display("vld_comp: %b, free: %b, en_comp: %b", vld_comp, free, en_comp);
        // $display("is_end: [%b, %b], is_end_comp: %b", is_end[0], is_end[1], is_end_comp);
        $display("en_cnt: %1d, expander2rrb_ren_cnt: %1d", en_cnt, expander2rrb_ren_cnt);
        // $display("after_end: [%b, %b]", after_end[0], after_end[1]);
        // for (int e = 0; e < 2; ++e)
        //     $display("off_n[%1d]: [%2d, %2d, %2d, %2d, %2d]",
        //         e, off_n[e][0],off_n[e][1],off_n[e][2],off_n[e][3],off_n[e][4]
        //     );
        $display("md: [%b, %b, %b, %b]",
            cands_comp[0].md,cands_comp[1].md,cands_comp[2].md,cands_comp[3].md
        );
        $display("off_n_comp: [%2d, %2d, %2d, %2d, %2d]",
            off_n_comp[0],off_n_comp[1],off_n_comp[2],off_n_comp[3],off_n_comp[4]
        );
    endtask
        
`endif

    `CNT_TYPE(4) align2expander_ren_cnt;
    `CNT_TYPE(4) expander2align_used_scnt; // FIXME: unused
    BTQ_CAND[3:0] expander2align_dat;

    fifo #(
        .DEPTH(8),
        .WIDTH($bits(BTQ_CAND)),
        .NUM_RPORTS(4),
        .NUM_WPORTS(4),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(72)
    ) expander (
        .clock,
        .reset,
        .flush,

        // >> unused inputs
        .flush_snap ('0),
        .clmsk      ('0),
        .wr_bmask   ('0),
        // << unused inputs

        .wr_en_cnt  (en_cnt),
        .wr_data    (cands_comp),
        .rd_en_cnt  (align2expander_ren_cnt),
        .rd_data    (expander2align_dat),
        .free_scnt  (free_scnt),
        .used_scnt  (expander2align_used_scnt)
    );

    // fifo_barrel #(
    //     .DEPTH(8),
    //     .WIDTH($bits(BTQ_CAND)),
    //     .RPORTS(4),
    //     .WPORTS(4)
    // ) expander (
    //     .clock,
    //     .reset,
    //     .flush,

    //     .wvld_cnt   (en_cnt),
    //     .wdat       (cands_comp),
    //     .rrdy_cnt   (align2expander_ren_cnt),
    //     .rdat       (expander2align_dat),
    //     .wrdy_cnt   (free_scnt),
    //     .rvld_cnt   (expander2align_used_scnt)
    // );

    always_ff @(posedge clock) begin
        cur.off <= off_n_comp[en_cnt] & ~{$bits(FB_OFF){after_end_comp[en_cnt]}};
        cur.base<= base_n[expander2rrb_ren_cnt];

        if (flush) begin
            cur.off <= cbru_in.flush_fb_off;
            cur.base<= cbru_in.flush_fb_base;
        end

        if (reset) begin
            cur.off <= '0;
            cur.base<= '0;
        end
    end


    IF_ID_PKT[3:0]  align2ibuf_dat;
    `CNT_TYPE(4)    align2ibuf_wen_cnt;
    `CNT_TYPE(4)    ibuf2align_rdy_scnt;

    align align0 (
        .clock          (clock),
        .reset          (reset),
        .flush          (cbru_in.flush),

        .expander_in_dat     (expander2align_dat),
        .expander_out_ren_cnt(align2expander_ren_cnt),

        .irq_in_vld     (irq2align_vld),
        .irq_in_dat     (irq2align_dat),
        .irq_out_ren_cnt(align2irq_ren_cnt),

        .btq_in,
        .btq_out,

        .ibuf_in_rdy_scnt   (ibuf2align_rdy_scnt),
        .ibuf_out_wen_cnt   (align2ibuf_wen_cnt),
        .ibuf_out_dat       (align2ibuf_dat)
    );


    `CNT_TYPE(N) used_scnt;
    assign d_out.wen_cnt = `MIN(used_scnt, d_in.rdy_scnt);
    fifo #(
        .DEPTH(4*N),
        .WIDTH($bits(IF_ID_PKT)),
        .NUM_RPORTS(N),
        .NUM_WPORTS(4),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(48)
    ) insn_buf (
        .clock,
        .reset,
        .flush,

        // >> unused inputs
        .flush_snap ('0),
        .clmsk      ('0),
        .wr_bmask   ('0),
        // << unused inputs

        .wr_en_cnt  (align2ibuf_wen_cnt),
        .wr_data    (align2ibuf_dat),
        .rd_en_cnt  (d_out.wen_cnt),
        .rd_data    (d_out.dat),
        .free_scnt  (ibuf2align_rdy_scnt),
        .used_scnt  (used_scnt)
    );

    // fifo_barrel #(
    //     .DEPTH(4*N),
    //     .WIDTH($bits(IF_ID_PKT)),
    //     .RPORTS(N),
    //     .WPORTS(4)
    // ) insn_buf (
    //     .clock,
    //     .reset,
    //     .flush,

    //     // .rvld_cnt   (),
    //     // .rrdy_cnt   (),
    //     // .rdat       (),

    //     // .wvld_cnt,
    //     // .wrdy_cnt,
    //     // .wdat

    //     .wvld_cnt   (align2ibuf_wen_cnt),
    //     .wdat       (align2ibuf_dat),
    //     .rrdy_cnt   (d_out.wen_cnt),
    //     .rdat       (d_out.dat),
    //     .wrdy_cnt   (ibuf2align_rdy_scnt),
    //     .rvld_cnt   (used_scnt)
    // );

    always_ff @(posedge clock) begin
        iqq <= iqq_n;
        idat<= idat_n;

        if (reset | flush) begin
            iqq.vld <= '0;
            idat.vld<= '0;
        end

    end
endmodule