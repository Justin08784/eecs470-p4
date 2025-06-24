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

// icache response queue
module irq #(
    parameter DEPTH=IRQ_SZ,
    type PTR=`IDX_TYPE(DEPTH)
) (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,

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
    output  `CNT_TYPE(2)    vld_scnt,
    input   `CNT_TYPE(2)    ren_cnt,
    output  ICACHE_RESPONSE [1:0]   rdat
);
    PTR [2:0] rd_idxs_n;

    logic [DEPTH-1:0] cpl;
    ICACHE_RESPONSE [DEPTH-1:0] state;

    `CNT_TYPE(2) used_scnt, free_scnt;

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

    logic [1:0] rwin_cpl;
    logic       rwin_ncpl_any;
    `IDX_TYPE(2)rwin_ncpl_idx;
    generate
    for (genvar i = 0; i < 2; ++i) begin
        assign rwin_cpl[i]  = cpl[rd_idxs_n[i]];
        assign rdat[i]      = state[rd_idxs_n[i]];
    end
    endgenerate
    ffs #(
        .VECW(2)
    ) ff_ncpl (
        .i_vec(~rwin_cpl),
        .o_vld(rwin_ncpl_any),
        .o_idx(rwin_ncpl_idx)
    );

    assign rdy_scnt = free_scnt;

    assign vld_scnt = `MIN(
        used_scnt,
        rwin_ncpl_any ? rwin_ncpl_idx : 2
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            state   <= '0;
            cpl     <= '1;
        end else if (flush) begin
            cpl     <= '1;

        end else begin
            for (int i = 0; i < 2; ++i) begin
                int cur;
                if (!cen[i])
                    continue;
                cur = cidx[i];

                cpl  [cur]      <= 1;
                state[cur].blk  <= cdat.data[i];
                state[cur].md   <= cdat.insn_md[i];
            end

            for (int i = 0; i < `MIN(wen_cnt, 2); ++i) begin
                int cur;
                cur = wr_idxs_n[i];

                cpl  [cur]          <= 0;
                state[cur].dw       <=  wdat[i].dw;
                state[cur].off      <=  wdat[i].off;
                state[cur].fmsk     <=  wdat[i].fmsk;
                state[cur].is_end   <=  wdat[i].is_end;
            end

        end
    end


`ifdef DEBUG
    task print_irq;
        $display(">> IRQ");
        $display("vld_scnt: %d, rdy_scnt: %d", vld_scnt, rdy_scnt);
        $display("ren_cnt: %d, wen_cnt: %d", ren_cnt, wen_cnt);
        $display("rd[%d, %d, %d], wr[%d, %d, %d]",
            rd_idxs_n[0],
            rd_idxs_n[1],
            rd_idxs_n[2],
            wr_idxs_n[0],
            wr_idxs_n[1],
            wr_idxs_n[2]
        );
        for (int i = 0; i < IRQ_SZ; ++i)
            $display("irq[%d]: cpl: %b, dw: %d, off: [%d, %d], fmsk: %b, is_end: %b, blk: [%x, %x]",
                i,
                cpl[i],
                state[i].dw,
                state[i].off[0],
                state[i].off[1],
                state[i].fmsk,
                state[i].is_end,
                state[i].blk.word_level[0],
                state[i].blk.word_level[1]
            );
    endtask
`endif


endmodule


// combinational align
module align (
    // read (re-read buffer)
    // input   `CNT_TYPE(2)    rrb_in_vld_scnt, // do we even need this?
    input   FTQ_ENTRY[1:0]  rrb_in_dat,
    output  `CNT_TYPE(2)    rrb_out_ren_cnt,

    // read (icache response queue)
    input   `CNT_TYPE(2)    irq_in_vld_scnt,
    input   ICACHE_RESPONSE[1:0] irq_in_dat,
    output  `CNT_TYPE(2)    irq_out_ren_cnt,

    // write (branch target queue)
    input   btq2fetch       btq_in,
    output  fetch2btq       btq_out,

    input   `CNT_TYPE(4)    ibuf_in_rdy_scnt,
    output  `CNT_TYPE(4)    ibuf_out_wen_cnt,
    output  IF_ID_PKT[3:0]  ibuf_out_dat

);
    localparam W_PER_DW = 2;
    localparam NUM_DW   = 2;
    localparam NUM_FTQ  = 2;
    localparam NUM_W    = NUM_DW*W_PER_DW;

    initial begin
        /* impl is hardcoded/tuned to the following params */
        assert (NUM_DW == 2)    else $fatal;
        assert (NUM_FTQ == 2)   else $fatal;
    end

    /*
    raw: not aligned
    bal: block aligned (compaction WITHIN blocks)
    wal: block AND word aligned (compaction across entire array) */

    logic [NUM_W-1:0][3:0] raw_off;
    WADDR [NUM_W-1:0] raw_pc;
    BRANCH_MD [NUM_W-1:0] raw_md;
    struct packed {
        logic [NUM_W-1:0] brch, fmsk, irq_vld, is_end, indw_last;
        IF_ID_PKT [NUM_W-1:0] f_dat;
    } raw, bal, wal;
    
    struct packed {
        logic   [1:0] blk;  // compact inside block i?
        logic   mid;        // cross from b1 into b0?
    } shl; // shift lefts

    logic [NUM_W:0][`CNT_SIZE(N)-1:0] brch_prefix_cnt;
    compactor #(
        .REQW(NUM_W),
        .GNTW(N)
    ) comp_brch (
        .req        (raw.fmsk & raw.brch),
        .lim_cnt    (),
        .prefix_cnt (brch_prefix_cnt),
        .gnt_cnt    ()
    );

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
            assign raw.brch [flat_idx]  = cur.md[w].brch;
            assign raw.fmsk [flat_idx]  = cur.fmsk[w];
            assign raw.irq_vld[flat_idx]= (b < irq_in_vld_scnt);
            assign raw.is_end[flat_idx] = cur.is_end[w];
            assign raw.f_dat [flat_idx]  = '{
                PC      : raw_pc[flat_idx],
                inst    : cur.blk.word_level[w],
                btq_idx : btq_in.btq_idxs_n[brch_prefix_cnt[flat_idx]],
                ras_snap: '0 // FIXME
            };
        end
    end
    endgenerate

    generate
    assign shl = '{
        blk : {~raw.fmsk[2], ~raw.fmsk[0]},
        mid : |(~raw.fmsk[1:0])
            /* since each cache line contains at least 1 valid word,
            the cross (mid) shift is at most 1 */
    };

    for (genvar b = 0; b < NUM_DW; ++b) begin : block_align
        localparam lo = W_PER_DW*b;
        localparam hi = W_PER_DW*(b+1) - 1;

        // full shift controls (cannot permit duplicates)
        assign bal.brch     [hi:lo] = raw.brch      [hi:lo] >> shl.blk[b];
        assign bal.fmsk     [hi:lo] = raw.fmsk      [hi:lo] >> shl.blk[b];
        assign bal.irq_vld  [hi:lo] = raw.irq_vld   [hi:lo] >> shl.blk[b];
        assign bal.is_end   [hi:lo] = raw.is_end    [hi:lo] >> shl.blk[b];
        assign bal.indw_last[hi:lo] = raw.indw_last [hi:lo] >> shl.blk[b];

        // bleed/copy shift data (duplicates fine–– guarded by controls)
        assign bal.f_dat    [lo]    = shl.blk[b] ? raw.f_dat[hi] : raw.f_dat[lo];
        assign bal.f_dat    [hi]    = raw.f_dat[hi];
    end

    // word_align
    assign wal.brch     [0]     = bal.brch      [0];
    assign wal.fmsk     [0]     = bal.fmsk      [0];
    assign wal.irq_vld  [0]     = bal.irq_vld   [0];
    assign wal.is_end   [0]     = bal.is_end    [0];
    assign wal.indw_last[0]     = bal.indw_last [0];

    assign wal.brch     [3:1]   = bal.brch      [3:1]   >> shl.mid;
    assign wal.fmsk     [3:1]   = bal.fmsk      [3:1]   >> shl.mid;
    assign wal.irq_vld  [3:1]   = bal.irq_vld   [3:1]   >> shl.mid;
    assign wal.is_end   [3:1]   = bal.is_end    [3:1]   >> shl.mid;
    assign wal.indw_last[3:1]   = bal.indw_last [3:1]   >> shl.mid;

    assign wal.f_dat    [0]     = bal.f_dat[0];
    assign wal.f_dat    [3]     = bal.f_dat[3];
    assign wal.f_dat    [1]     = shl.mid ? bal.f_dat[2] : bal.f_dat[1];
    assign wal.f_dat    [2]     = shl.mid ? bal.f_dat[3] : bal.f_dat[2];

    typedef struct packed {
        `CNT_TYPE(NUM_W) wr_ibuf, wr_btq, rd_rrb;
        `CNT_TYPE(2) rd_irq;
    } RESO;

    struct packed {
        logic   [NUM_W-1:0] req, gnt, rng;
        RESO    [NUM_W-1:0] req_res;
        RESO    gnt_res;
        struct packed {
            logic wr_ibuf, wr_btq, rd_rrb, rd_irq;
        } [NUM_W-1:0] sat;
    } ctl;

    assign ctl.req = wal.irq_vld & wal.fmsk & wal.indw_last;
        /* ^^ Q: indw_last guard, why? A: do not allow partial cache line consumption */
    for (genvar w = 0; w < NUM_W; ++w) begin
        localparam sz = `CNT_SIZE(w+1);
        assign ctl.req_res[w].wr_ibuf   [sz-1:0] = sz'($countones(wal.fmsk[w:0]));
        assign ctl.req_res[w].wr_btq    [sz-1:0] = sz'($countones(wal.brch[w:0]));
        assign ctl.req_res[w].rd_rrb    [sz-1:0] = sz'($countones(wal.is_end[w:0]));
        assign ctl.req_res[w].rd_irq             = unsigned'(sz'($countones(wal.indw_last[w:0])));
            // FIXME FIXME ^^ if we dont do unsigned' the rd_irq goes to 3 sometimes wtf

        if (sz < `CNT_SIZE(NUM_W)) begin
            assign ctl.req_res[w].wr_ibuf  [`CNT_SIZE(NUM_W)-1:sz] = '0;
            assign ctl.req_res[w].wr_btq   [`CNT_SIZE(NUM_W)-1:sz] = '0;
            assign ctl.req_res[w].rd_rrb   [`CNT_SIZE(NUM_W)-1:sz] = '0;
        end
    end

    assign ctl.gnt_res.wr_ibuf  = ibuf_in_rdy_scnt;
    assign ctl.gnt_res.wr_btq   = btq_in.rdy_scnt;
    assign ctl.gnt_res.rd_rrb   = 2;
        /* pc_gen guarantees that an ftq entry arrives in rrb BEFORE or SIMULTANEOUSLY WITH
        the earliest associated cache line request. However, the rrb exposes
        at most 2 FTQ entries to the aligner. */
    localparam rrb_sz = `CNT_SIZE(2);
    localparam btq_sz = `CNT_SIZE(N);
    assign ctl.rng = ctl.req & ctl.gnt; // rng = request and grant
    for (genvar w = 0; w < NUM_W; ++w) begin
        localparam sz = `CNT_SIZE(w+1);
        assign ctl.sat[w].wr_ibuf   = ctl.req_res[w].wr_ibuf[sz-1:0] <= ctl.gnt_res.wr_ibuf;
        assign ctl.sat[w].wr_btq    = ctl.req_res[w].wr_btq [sz-1:0] <= ctl.gnt_res.wr_btq[btq_sz-1:0];
        assign ctl.sat[w].rd_rrb    = ctl.req_res[w].rd_rrb [sz-1:0] <= ctl.gnt_res.rd_rrb[rrb_sz-1:0];
        assign ctl.sat[w].rd_irq    = 1;
        assign ctl.gnt[w] = &ctl.sat[w];
    end
    endgenerate

    logic iss_any;
    `IDX_TYPE(NUM_W) iss_idx;
    assign iss_any = |ctl.rng;
    always_comb begin
        iss_idx = 0;
        for (int w = 0; w < NUM_W; ++w) begin
            if (ctl.rng[w])
                iss_idx = w; // find highest set
        end
    end

    assign ibuf_out_wen_cnt = !iss_any ? 0 : ctl.req_res[iss_idx].wr_ibuf;
    assign btq_out.wen_cnt  = !iss_any ? 0 : ctl.req_res[iss_idx].wr_btq;
    assign irq_out_ren_cnt  = !iss_any ? 0 : ctl.req_res[iss_idx].rd_irq;
    assign rrb_out_ren_cnt  = !iss_any ? 0 : ctl.req_res[iss_idx].rd_rrb;

    assign ibuf_out_dat     = wal.f_dat;

    logic [NUM_W-1:0] rrb_prefix;
    assign rrb_prefix = (rrb_prefix | (raw.fmsk & raw.is_end)) << 1;

    generate
    struct packed {
        logic   [NUM_W-1:0]        is_tail;
        WADDR   [NUM_W-1:0]        PC;
        logic   [NUM_W-1:0][3:0]   off;
        logic   [NUM_W-1:0]        pred;
        WADDR   [NUM_W-1:0]        pred_tgt;
        logic   [NUM_W-1:0]        always_take;
        FTB_MD1 [NUM_W-1:0]        md;

        logic   [NUM_W-1:0]        hit;
        logic   [NUM_W-1:0]        hit_slot;
        logic   [NUM_W-1:0]        slot_idx;
        logic   [NUM_W-1:0][GHR_LEN-1:0] hash; // gshare hash index
        logic   [NUM_W-1:0][`IDX_SIZE(GHR_BUF_SZ)-1:0] ghr_base;
    } btq_wr_cand, btq_wr_comp;

    for (genvar w = 0; w < NUM_W; ++w) begin
        FTQ_ENTRY r;
        logic is_end, ve0, ve1;
        assign ve0 = r.slot[0].vld && (r.slot[0].off == raw_off[w]);
        assign ve1 = r.slot[1].vld && (r.slot[1].off == raw_off[w]);

        assign r = rrb_in_dat[rrb_prefix[w]];
        assign is_end = raw.is_end[w];
        assign btq_wr_cand.is_tail     [w] = (r.pred_idx == 1) && is_end;
            /* FIXME (unsure): Probably not necessary to check for "off_geq_tail",
            i.e. (r.pred_idx == 1) && (off_n[i] >= r.off), because branches after (>)
            the tail slot would not even be in the same fetch block? */
        assign btq_wr_cand.PC          [w] = raw_pc[w];
        assign btq_wr_cand.off         [w] = raw_off[w];
        assign btq_wr_cand.pred        [w] = !r.ft && is_end;
        assign btq_wr_cand.pred_tgt    [w] = r.base_n;
        assign btq_wr_cand.always_take [w] = !r.ft && is_end ? r.always_take : 0;
        assign btq_wr_cand.md          [w] = raw_md[w];
            // TODO: fix RAS if pred ret but not ret (likewise for call)

        assign btq_wr_cand.hit         [w] = r.hit;
        assign btq_wr_cand.hit_slot    [w] = ve0 || ve1;
        assign btq_wr_cand.slot_idx    [w] = ve1;
        assign btq_wr_cand.hash        [w] = '0; // FIXME
        assign btq_wr_cand.ghr_base    [w] = '0; // FIXME
    end
    endgenerate

    always_comb begin
        btq_wr_comp = '0;
        for (int w = 0; w < NUM_W; ++w) begin
            int win_idx;
            win_idx = brch_prefix_cnt[w];

            btq_wr_comp.is_tail     [win_idx] = btq_wr_cand.is_tail [w];
            btq_wr_comp.PC          [win_idx] = btq_wr_cand.PC      [w];
            btq_wr_comp.off         [win_idx] = btq_wr_cand.off     [w];
            btq_wr_comp.pred        [win_idx] = btq_wr_cand.pred    [w];
            btq_wr_comp.pred_tgt    [win_idx] = btq_wr_cand.pred_tgt[w];
            btq_wr_comp.always_take [win_idx] = btq_wr_cand.always_take[w];
            btq_wr_comp.md          [win_idx] = btq_wr_cand.md      [w];
            btq_wr_comp.hit         [win_idx] = btq_wr_cand.hit     [w];
            btq_wr_comp.hit_slot    [win_idx] = btq_wr_cand.hit_slot[w];
            btq_wr_comp.slot_idx    [win_idx] = btq_wr_cand.slot_idx[w];
            btq_wr_comp.hash        [win_idx] = btq_wr_cand.hash    [w]; // FIXME
            btq_wr_comp.ghr_base    [win_idx] = btq_wr_cand.ghr_base[w]; // FIXME
        end
    end

    generate
    assign btq_out.is_tail  [N-1:0] = btq_wr_comp.is_tail   [N-1:0];
    assign btq_out.PC       [N-1:0] = btq_wr_comp.PC        [N-1:0];
    assign btq_out.off      [N-1:0] = btq_wr_comp.off       [N-1:0];
    assign btq_out.pred     [N-1:0] = btq_wr_comp.pred      [N-1:0];
    assign btq_out.pred_tgt [N-1:0] = btq_wr_comp.pred_tgt  [N-1:0];
    assign btq_out.always_take[N-1:0]=btq_wr_comp.always_take[N-1:0];
    assign btq_out.md       [N-1:0] = btq_wr_comp.md        [N-1:0];
    assign btq_out.hit      [N-1:0] = btq_wr_comp.hit       [N-1:0];
    assign btq_out.hit_slot [N-1:0] = btq_wr_comp.hit_slot  [N-1:0];
    assign btq_out.slot_idx [N-1:0] = btq_wr_comp.slot_idx  [N-1:0];
    assign btq_out.hash     [N-1:0] = btq_wr_comp.hash      [N-1:0]; // FIXME
    assign btq_out.ghr_base [N-1:0] = btq_wr_comp.ghr_base  [N-1:0]; // FIXME
    endgenerate


`ifdef DEBUG
    task print_align;
        $display("fyooooo. iss_any: %b, iss_idx: %d, raw.fmsk: %b, wal.fmsk: %b, req: %b", iss_any, iss_idx, raw.fmsk, wal.fmsk, ctl.req);

        $display("rrb_prefix: %b, wal.indw_last: %b", rrb_prefix, wal.indw_last);
        $display("shl.blk[0]: %b, shl.blk[1]: %b, shl.mid: %b",
            shl.blk[0],
            shl.blk[1],
            shl.mid
        );

        $display("::f_wen_cnt: %d, %b", ibuf_out_wen_cnt, ibuf_out_wen_cnt);
        $display("::btq_wen_cnt: %d", btq_out.wen_cnt);
        $display("::rrb_ren_cnt: %d", rrb_out_ren_cnt);
        $display("::irq_ren_cnt %d", irq_out_ren_cnt);
        for (int i = 0; i < 4; ++i) begin
            $display("::irq_in[%d]: pc: %d, inst: %x",
                i,
                raw_pc[i],
                irq_in_dat[i/2].blk.word_level[i%2]
            );

        end

        $display("wal.indw_last: %0d, %0d, %0d, %0d",
            $countones(wal.indw_last[0:0]),
            $countones(wal.indw_last[1:0]),
            $countones(wal.indw_last[2:0]),
            $countones(wal.indw_last[3:0])
        );

        $display("req_res.rd_irq: %0d, %0d, %0d, %0d",
            ctl.req_res[0].rd_irq,
            ctl.req_res[1].rd_irq,
            ctl.req_res[2].rd_irq,
            ctl.req_res[3].rd_irq
        );

        for (int i = 0; i < 4; ++i) begin
            $display("::f_dat[%d]: pc: %d, inst: %x",
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
    input   flush,
    input   BMASK clmsk,
    // input   WADDR flush_PC,
        /*
        WRONG >> 
            FIXME: this should/would be an FB base...?
        <<
        If branch was mispred NT-resolved T, then flush_PC indeed will be an fb_base.
        However, if branch was mispred T-resolved NT, then flush_PC may NOT be an
        fb_base–– instead flush_PC is more likely to be a nonzero offset INO the FB.
        */
    input   WADDR flush_fb_base,
    input   logic [3:0] flush_pc_off,

    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   btq2fetch   btq_in,
    output  fetch2btq   btq_out,

    // execute
    input   execute2complete_bru cbru_in,

    input   rename2snap_bus snap_in, // unused

    output  fetch2mem   mem_out,
    input   mem2fetch   mem_in

);
    // bpu <-> ftq plumbing
    struct packed {
        logic       en;
        FTQ_ENTRY   dat;
    } bpu2ftq;
    struct packed {
        logic       rdy;
    } ftq2bpu;

    bpu bpu0 (
        .clock,
        .reset,

        .flush,
        .flush_fb_base,
        .flush_pc_off,
        .clmsk,
        .cbru_in,

        .i_uen      (btq_in.bp_upd.en),
        .i_udat     (btq_in.bp_upd.dat),

        .i_ftq_rdy  (ftq2bpu.rdy),
        .o_ftq_en   (bpu2ftq.en),
        .o_ftq_dat  (bpu2ftq.dat)
    );


    // ftq <-> pc_gen plumbing
    FTQ_ENTRY [1:0] ftq2pc_gen_dat;
    `CNT_TYPE(2)    ftq2pc_gen_vld_scnt;
    `CNT_TYPE(2)    pc_gen2ftq_ren_cnt;

    ftq ftq0 (
        .clock,
        .reset,
        .flush,

        .rdy        (ftq2bpu.rdy),
        .wen        (bpu2ftq.en),
        .wdat       (bpu2ftq.dat),

        .vld_scnt   (ftq2pc_gen_vld_scnt),
        .rdat       (ftq2pc_gen_dat),
        .ren_cnt    (pc_gen2ftq_ren_cnt)
    );

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

        .flush_fb_base,
        .flush_pc_off,

        .ftq_in_vld_scnt    (ftq2pc_gen_vld_scnt),
        .ftq_in_dat         (ftq2pc_gen_dat),
        .ftq_out_ren_cnt    (pc_gen2ftq_ren_cnt),

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
    `CNT_TYPE(2)        irq2align_vld_scnt;
    `CNT_TYPE(2)        align2irq_ren_cnt;

    irq irq0 (
        .clock,
        .reset,
        .flush,
        .clmsk  ('0),

        .wr_idxs_n  (irq_wr_idxs_n),
        .rdy_scnt   (ixq2pc_gen_rdy_scnt),  // TODO: change irq when has backpressure
        .wen_cnt    (pc_gen2ixq_wen_cnt),
        .wdat       (pc_gen2ixq_dat),

        .cen        (idat.vld),
        .cidx       (idat.irq_idx),
        .cdat       (idat.mem_dat),

        .vld_scnt   (irq2align_vld_scnt),
        .ren_cnt    (align2irq_ren_cnt),
        .rdat       (irq2align_dat)
    );

    FTQ_ENTRY[1:0]  rrb2align_dat;
    `CNT_TYPE(2)    align2rrb_ren_cnt;

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
        .rd_en_cnt  (align2rrb_ren_cnt),
        .rd_data    (rrb2align_dat),
        .free_scnt  (rrb2pc_gen_rdy_scnt),
        .used_scnt  ()
    );

    IF_ID_PKT[3:0]   align2ibuf_dat;
    `CNT_TYPE(4)        align2ibuf_wen_cnt;
    `CNT_TYPE(4)        ibuf2align_rdy_scnt;

    align align0 (
        .rrb_in_dat     (rrb2align_dat),
        .rrb_out_ren_cnt(align2rrb_ren_cnt),

        .irq_in_vld_scnt(irq2align_vld_scnt),
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

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            iqq.vld <= '0;
            idat.vld<= '0;
            // iqq     <= '0;
            // idat    <= '0;

        end else begin
            iqq     <= iqq_n;
            idat    <= idat_n;

        end

    end

`ifdef FORMAL
    /* Since the FTQ_ENTRY does not store the current base (it only stores base_n),
    it is *vital* that upon reset, flush, or–– in the future–– steer, the BPU and
    pc_gen are both reset to same fb base AND in-fb offset. */

    property bpu_pcgen_converge_after_redirect;
        @(posedge clock)
            disable iff (reset)
            flush |=> // TODO: add steer too
                (bpu0.pc_reg== pc_gen0.cur.base) &&
                (bpu0.off   == pc_gen0.cur.off);
    endproperty

    Bpu_Pcgen_Converge_After_Redirect: assert property(bpu_pcgen_converge_after_redirect)
        else $fatal;
`endif
endmodule