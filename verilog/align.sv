`include "sys_defs.svh"

// combinational align
module align(
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
    output  IF_ID_PACKET[3:0]   ibuf_out_dat

);
    localparam W_PER_DW = 2;
    localparam NUM_DW = 2;
    localparam NUM_W = NUM_DW*W_PER_DW;
    localparam N = `N;

    // typedef struct packed {
    //     DWADDR      dw;
    //     logic       woff;   // in-dw word offset
    //     logic [3:0] off;    // in-fb word offset
    //     // logic       fmsk;
    //     logic       is_end;
        
    //     INST        inst;
    //     BRANCH_MD   md;
    // } IRES_WORD;

    /*
    raw: not aligned
    bal: block aligned (compaction WITHIN blocks)
    wal: block AND word aligned (compaction across entire array) */

    struct packed {
        logic [NUM_W-1:0] brch, fmsk, is_end, indw_last;
        IF_ID_PACKET [NUM_W-1:0] f_dat;
    } raw, bal, wal;
    
    struct packed {
        logic   [1:0] blk;  // compact inside block i?
        logic   mid;        // cross from b1 into b0?
    } shl; // shift lefts

    generate
    logic [NUM_W-1:0] brch_prefix;
    logic [NUM_DW-1:0][W_PER_DW-1:0] before_indw_last;

    assign brch_prefix = (brch_prefix | (raw.fmsk & raw.brch)) << 1;
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

            assign raw.brch [flat_idx]  = cur.md[w].brch;
            assign raw.fmsk [flat_idx]  = cur.fmsk[w];
            assign raw.is_end[flat_idx] = cur.is_end[w];
            assign raw.f_dat [flat_idx]  = '{
                PC      : {cur.dw, w[0]},
                inst    : cur.blk.word_level[w],
                btq_idx : btq_in.btq_idxs_n[brch_prefix[flat_idx]],
                ras_snap: '0 // FIXME

                // dw      : cur.dw,
                // woff    : w,
                // off     : cur.off[w],
                // is_end  : cur.is_end[w],
                // dat     : cur.blk.word_level[w],
                // md      : cur.md[w]
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

    // struct packed {
    //     logic [NUM_W-1:0] brch, fmsk, is_end, indw_last;
    //     IF_ID_PACKET [NUM_W-1:0] f_dat;
    // );

    for (genvar b = 0; b < NUM_DW; ++b) begin : block_align
        localparam lo = W_PER_DW*b;
        localparam hi = W_PER_DW*(b+1) - 1;

        // full shift controls (cannot permit duplicates)
        assign bal.brch     [hi:lo] = raw.brch      [hi:lo] >> shl.blk[b];
        assign bal.fmsk     [hi:lo] = raw.fmsk      [hi:lo] >> shl.blk[b];
        assign bal.is_end   [hi:lo] = raw.is_end    [hi:lo] >> shl.blk[b];
        assign bal.indw_last[hi:lo] = raw.indw_last [hi:lo] >> shl.blk[b];

        // bleed/copy shift data (duplicates fine–– guarded by controls)
        assign bal.f_dat    [lo]    = shl.blk[b] ? raw.f_dat[hi] : raw.f_dat[lo];
        assign bal.f_dat    [hi]    = raw.f_dat[hi];
    end

    // word_align
    assign wal.brch     [3:1]   = bal.brch      [3:1]   >> shl.mid;
    assign wal.fmsk     [3:1]   = bal.fmsk      [3:1]   >> shl.mid;
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

    for (genvar w = 0; w < NUM_W; ++w) begin
        localparam sz = `CNT_SIZE(w+1);
        assign ctl.req[w] = wal.fmsk[w];
        assign ctl.req_res[w].wr_ibuf   [sz-1:0] = sz'($countones(wal.fmsk[w:0]));
        assign ctl.req_res[w].wr_btq    [sz-1:0] = sz'($countones(wal.brch[w:0]));
        assign ctl.req_res[w].rd_rrb    [sz-1:0] = sz'($countones(wal.is_end[w:0]));
        assign ctl.req_res[w].rd_irq             = sz'($countones(wal.indw_last[w:0]));

        if (sz < `CNT_SIZE(NUM_W)) begin
            assign ctl.req_res[w].wr_ibuf  [`CNT_SIZE(NUM_W)-1:sz] = '0;
            assign ctl.req_res[w].wr_btq   [`CNT_SIZE(NUM_W)-1:sz] = '0;
            assign ctl.req_res[w].rd_rrb   [`CNT_SIZE(NUM_W)-1:sz] = '0;
        end
    end

    assign ctl.gnt_res.wr_ibuf  = ibuf_in_rdy_scnt;
    assign ctl.gnt_res.wr_btq   = btq_in.btq_rdy_scnt;
    assign ctl.gnt_res.rd_rrb   = 2;
        /* pc_gen guarantees that an ftq entry arrives in rrb BEFORE or SIMULTANEOUSLY WITH
        the earliest associated cache line request. However, the rrb exposes
        at most 2 FTQ entries to the aligner. */
    localparam rrb_sz = `CNT_SIZE(2);
    localparam btq_sz = `CNT_SIZE(N);
    for (genvar w = 0; w < NUM_W; ++w) begin
        localparam sz = `CNT_SIZE(w+1);
        assign ctl.sat[w].wr_ibuf   = ctl.req_res[w].wr_ibuf[sz-1:0] <= ctl.gnt_res.wr_ibuf;
        assign ctl.sat[w].wr_btq    = ctl.req_res[w].wr_btq [sz-1:0] <= ctl.gnt_res.wr_btq[btq_sz-1:0];
        assign ctl.sat[w].rd_rrb    = ctl.req_res[w].rd_rrb [sz-1:0] <= ctl.gnt_res.rd_rrb[rrb_sz-1:0];
        assign ctl.sat[w].rd_irq    = 1;
        assign ctl.gnt[w] = &ctl.sat[w];
        assign ctl.rng[w] = ctl.req[w] & ctl.gnt[w]; // rng = request and grant
    end



    // assign bal = '{
    //     brch: raw.brch >> shl

    // }
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

    // generate
    // if (iss_any) begin
    assign ibuf_out_wen_cnt = !iss_any ? 0 : ctl.req_res[iss_idx].wr_ibuf;
    assign btq_out.en_cnt   = !iss_any ? 0 : ctl.req_res[iss_idx].wr_btq;
    assign irq_out_ren_cnt  = !iss_any ? 0 : ctl.req_res[iss_idx].rd_irq;
    assign rrb_out_wen_cnt  = !iss_any ? 0 : ctl.req_res[iss_idx].rd_rrb;

    // end else begin
    //     assign ibuf_out_wen_cnt = 0;
    //     assign btq_out.en_cnt   = 0;
    //     assign irq_out_ren_cnt  = 0;
    //     assign rrb_out_wen_cnt  = 0;

    // end
    // endgenerate

    assign ibuf_out_dat     = wal.f_dat;


    // always_comb begin
    //     for (genvar w = 0; w < NUM_W; ++w) begin
    //         logic   win_idx; // index into btq write window
    //         logic   eq_end;
    //         win_idx = brch_prefix[w];
    //         eq_end  = ires_l1[w].off == r.off;

    //         f_dat[i].btq_idx = btq_in.btq_idxs_n[win_idx];

    //         btq_out.is_tail     [win_idx] = (r.pred_idx == 1) && eq_end;
    //             /* FIXME (unsure): Probably not necessary to check for "off_geq_tail",
    //             i.e. (r.pred_idx == 1) && (off_n[i] >= r.off), because branches after (>)
    //             the tail slot would not even be in the same fetch block? */
    //         btq_out.PC          [win_idx] = pc_n[i];
    //         btq_out.off         [win_idx] = off_n[0][i];
    //         btq_out.pred        [win_idx] = !r.ft && eq_end;
    //         btq_out.pred_tgt    [win_idx] = r.base_n;
    //         btq_out.always_take [win_idx] = !r.ft && eq_end ? r.always_take : 0;
    //         btq_out.md          [win_idx] = md[i];
    //             // TODO: fix RAS if pred ret but not ret (likewise for call)

    //         btq_out.hit         [win_idx] = r.hit;
    //         btq_out.hit_slot    [win_idx] =
    //                 (r.slot[0].vld && (r.slot[0].off == off_n[0][i]))
    //             ||  (r.slot[1].vld && (r.slot[1].off == off_n[0][i]));
    //         btq_out.hash        [win_idx] = '0; // FIXME
    //         btq_out.ghr_base    [win_idx] = '0; // FIXME
    //     end
    // end


    logic [NUM_W:0][`CNT_SIZE(NUM_W)-1:0] words_prefix_cnt;
    compactor #(
        .REQW(NUM_W),
        .GNTW(NUM_W)
    ) comp_words (
        .req        (),
        .lim_cnt    (),
        .prefix_cnt (),
        .gnt_cnt    ()
    );
endmodule
