`include "sys_defs.svh"


/* NOTE:
Since the FTQ_ENTRY does not store the current base (it only stores base_n),
it is *vital* that upon reset, flush, or–– in the future–– steer, the BPU and
pc_gen are both reset to exact same base. Maybe use a runtime assertion like this?:

property p_never_diverge;
  @(posedge clock)
    disable iff (reset)
    pc_gen.cur.base == $past(BPU.fb_base);
endproperty
*/
module pc_gen #(
    parameter W_PER_DW      = 2, // num words per double-word / cache line
    parameter NUM_DW        = 2, // num double words we can process per cycle
    parameter NUM_FTQ       = 2, // num FTQ entries we can process per cycle
    type FB_OFF             =`IDX_TYPE(MAX_FB_SPAN),
    localparam  NUM_W       = NUM_DW*W_PER_DW
) (
    input   clock,
    input   reset,
    input   flush,

    input   WADDR       flush_fb_base,
    input   logic [3:0] flush_fb_off,
`ifdef PC_GEN_TEST_MODE
    input   struct packed {
        logic [3:0] off;
        WADDR       base;
        logic       inbuf;
    } reset_val,
`endif

    // ftq
    input   `CNT_TYPE(2)    ftq_in_vld_scnt,
    input   FTQ_ENTRY[1:0]  ftq_in_dat,
    output  `CNT_TYPE(2)    ftq_out_ren_cnt,

    // irq / iqq
    // FIXME: these ixq_out lines should be folded into a dat struct
    input   `CNT_TYPE(2)    ixq_in_rdy_scnt, // = `MIN(iqq_*, irq_*)
    output  `CNT_TYPE(2)    ixq_out_wen_cnt,
    output  pc_gen2ixq[1:0] ixq_out_dat,

    // FTQ buffer
    input   `CNT_TYPE(2)    rrb_in_rdy_scnt,
    output  `CNT_TYPE(2)    rrb_out_wen_cnt,
    output  FTQ_ENTRY[1:0]  rrb_out_dat
);
    localparam FB_OFF off_rst = '0;
    localparam WADDR base_rst = '0;
    localparam logic inbuf_rst = 0;

    initial begin
        /* impl is hardcoded/tuned to the following params */
        assert (NUM_DW == 2)    else $fatal;
        assert (NUM_FTQ == 2)   else $fatal;
    end

    struct packed {
        FB_OFF  off;
        WADDR   base;
        logic   inbuf; // FTQ entry allocated in buf?
    } cur;

    // Form indices: fb offsets, PCs, block DWs
    logic   [NUM_FTQ-1:0] base_woff;            // index: (ftq).
    FB_OFF  [NUM_FTQ-1:0][NUM_W:0]  nal_off_n;  // index: (ftq, word).
    logic   [NUM_FTQ-1:0][NUM_W-1:0]nal_is_end; // index: (ftq, word). nal = not cache line aligned
    generate
    assign base_woff[0] = cur.base[0] ^ cur.off[0]; // 1 bit add
    assign base_woff[1] = ftq_in_dat[0].base_n[0];

    assign nal_off_n[0][0] = cur.off;
    assign nal_off_n[1][0] = 0;
    for (genvar w = 1; w <= NUM_W; ++w) begin
        assign nal_off_n[0][w] = cur.off + `UCAST_FIT(w);
        assign nal_off_n[1][w] = w;
    end

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar w = 0; w < NUM_W; ++w) begin
            assign nal_is_end[e][w] = ftq_in_dat[e].off == nal_off_n[e][w];
        end
    end
    endgenerate


    FB_OFF  [NUM_FTQ-1:0][NUM_W:0]off_n;
    FB_OFF  [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] blk_off_n;
    logic   [NUM_FTQ-1:0][NUM_W-1:0]is_end_flat, fmsk_flat;
    logic   [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] is_end, fmsk;
    generate
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign off_n[e][0] = base_woff[e]
            ? '0
            : nal_off_n[e][0];

        for (genvar w = 1; w <= NUM_W; ++w) begin
            assign off_n[e][w] = base_woff[e]
                ? nal_off_n[e][w-1]
                : nal_off_n[e][w];
        end
    end

    logic   [NUM_FTQ-1:0][NUM_W-1:0] align_msk, after_end;
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        assign align_msk[e]     = {NUM_W{1'b1}} << base_woff[e];
        assign is_end_flat[e]   = nal_is_end[e] << base_woff[e];
    end
    for (genvar e = 0; e < NUM_FTQ; ++e)
        assign after_end[e] = (after_end[e] | is_end_flat[e]) << 1;
    assign fmsk_flat = align_msk & ~after_end;

    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar b = 0; b < NUM_DW; ++b) begin
            assign fmsk  [e][b] = fmsk_flat  [e][W_PER_DW*b +: W_PER_DW];
            assign is_end[e][b] = is_end_flat[e][W_PER_DW*b +: W_PER_DW];
            assign blk_off_n[e][b] = off_n[e][W_PER_DW*b +: W_PER_DW];
        end
    end

    logic   [NUM_FTQ-1:0][NUM_DW-1:0] blk_has_end;
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar b = 0; b < NUM_DW; ++b) begin
            assign blk_has_end[e][b]= |is_end[e][b];
        end
    end
    endgenerate

    DWADDR  [NUM_FTQ-1:0][NUM_DW-1:0] dws;
    generate
    WADDR   [NUM_FTQ-1:0] start_pc;
    assign start_pc[0] = cur.base + cur.off;
    assign start_pc[1] = ftq_in_dat[0].base_n;

    assign dws[0][0] = start_pc[0][13:1];
    assign dws[0][1] = start_pc[0][13:1] + `UCAST_FIT(1);
    assign dws[1][0] = start_pc[1][13:1];
    assign dws[1][1] = start_pc[1][13:1] + `UCAST_FIT(1);
    endgenerate

    FB_OFF  [NUM_FTQ-1:0][NUM_DW-1:0] pos_blk_off;
    generate
    for (genvar e = 0; e < NUM_FTQ; ++e) begin
        for (genvar b = 0; b < NUM_DW; ++b) begin
            assign pos_blk_off[e][b] = off_n[e][W_PER_DW*(b+1)];
        end
    end
    endgenerate

    logic   ftq1_vld;
    assign  ftq1_vld = ftq_in_vld_scnt[1];

    logic bhe00;
    logic bhe01;
    logic bhe10;
    logic bhe11;
    assign bhe00    = blk_has_end[0][0];
    assign bhe01    = blk_has_end[0][1];
    assign bhe10    = blk_has_end[1][0];
    assign bhe11    = blk_has_end[1][1];

    logic merge_l0, merge_l1;
    assign merge_l0 = bhe00 && !is_end[0][0][W_PER_DW-1] && ftq_in_dat[0].ft;
    assign merge_l1 = bhe01 && !is_end[0][1][W_PER_DW-1] && ftq_in_dat[0].ft;

    logic   [NUM_DW-1:0] adv_bidx;  // ignore corr. idx aft_bidx if not set
    logic   [NUM_DW-1:0] adv_blk;   // ignore corr. idx aft_blk if not set
    logic   [NUM_DW-1:0][`IDX_SIZE(NUM_FTQ)-1:0]  aft_bidx; // latest base idx we are going past
    logic   [NUM_DW-1:0][`IDX_SIZE(NUM_DW)-1:0]   aft_blk;  // latest block idx we are going past
    // ^^ assuming NUM_FTQ = 2, NUM_DW = 2, then these are just:
    // logic    [NUM_DW-1:0] aft_bidx;
    // logic    [NUM_DW-1:0] aft_blk;

    // ------------------------------------------------------------------
    // adv_*[0]
    // ------------------------------------------------------------------
    assign adv_bidx[0] = bhe00;
    assign aft_bidx[0] = bhe10 & merge_l0;
    assign adv_blk [0] = ~bhe00 | (merge_l0 & ~bhe10);
    assign aft_blk [0] = 0;
    // always_comb begin
    //     unique case (1'b1)
    //     bhe00 & ~merge_l0:  adv_blk [0] = 0;
    //     bhe00 &  merge_l0:  adv_blk [0] = ~bhe10;
    //     default:            adv_blk [0] = 1;
    //     endcase
    // end

    // always_comb begin
    //     adv_bidx[0] = 0;
    //     aft_bidx[0] = 0;
    //     adv_blk [0] = 0;
    //     aft_blk [0] = 0;

    //     unique case (1'b1)
    //     bhe00 & ~merge_l0: begin
    //         adv_bidx[0] = 1;
    //         aft_bidx[0] = 0;

    //         adv_blk [0] = 0;
    //     end

    //     bhe00 &  merge_l0: begin
    //         adv_bidx[0] = 1;
    //         aft_bidx[0] =  bhe10;

    //         adv_blk [0] = ~bhe10;
    //         aft_blk [0]= 0;
    //     end

    //     default: begin
    //         adv_bidx[0] = 0;

    //         adv_blk [0] = 1;
    //         aft_blk [0] = 0;
    //     end
    //     endcase
    // end

    // ------------------------------------------------------------------
    // adv_*[1]
    // ------------------------------------------------------------------
    assign adv_bidx[1] = bhe00 | bhe01;
    always_comb begin
        unique case (1'b1)
        merge_l0  &  bhe10: begin // even though we issue 1 at most, we still consume 2
            aft_bidx[1] = 1; // base adv by 2

            adv_blk [1] = 0;
        end

        merge_l0  & ~bhe10 &  bhe11: begin
            aft_bidx[1] = 1; // base adv by 2

            adv_blk [1] = 0;
        end

        merge_l0  & ~bhe10 & ~bhe11: begin
            aft_bidx[1] = 0; // base adv by 1

            adv_blk [1] = 1;
            aft_blk [1] = 1; // blk  adv by 2
        end

        merge_l1 &  bhe10: begin
            // assert(~bhe00);
            aft_bidx[1] = 1; // base adv by 2

            adv_blk [1] = 0;
        end

        merge_l1 & ~bhe10: begin
            // assert(~bhe00);
            aft_bidx[1] = 0; // base adv by 1

            adv_blk [1] = 1;
            aft_blk [1] = 0; // blk  adv by 1
        end

        (~merge_l0 & ~merge_l1) & ~bhe00 &  bhe01: begin
            aft_bidx[1] = 0;

            adv_blk [1] = 0;
        end

        (~merge_l0 & ~merge_l1) & ~bhe00 & ~bhe01: begin
            adv_blk [1] = 1;
            aft_blk [1] = 1; // blk  adv by 2
        end

        (~merge_l0 & ~merge_l1) &  bhe00 &  bhe10: begin
            aft_bidx[1] = 1;

            adv_blk [1] = 0;
        end

        (~merge_l0 & ~merge_l1) &  bhe00 & ~bhe10: begin
            aft_bidx[1] = 0;

            adv_blk [1] = 1;
            aft_blk [1] = 0;
        end

        default: begin // dont cares / impossibles
            aft_bidx[1] = 1'bx;
            adv_blk [1] = 1'bx;
            aft_blk [1] = 1'bx;
        end
        endcase
    end

    function FB_OFF [W_PER_DW-1:0] merge_off(
        FB_OFF[W_PER_DW-1:0] aoff, boff,
        logic [W_PER_DW-1:0] amsk, bmsk
    );
        FB_OFF [W_PER_DW-1:0] rv;
        for (int w = 0; w < W_PER_DW; ++w)
            rv[w] = (amsk[w] ? aoff[w] : '0) | (bmsk[w] ? boff[w] : '0);
        return rv;
    endfunction

    // Merging data
    FB_OFF  [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] mer_blk_off_n;
    logic   [NUM_FTQ-1:0][NUM_DW-1:0][W_PER_DW-1:0] mer_is_end, mer_fmsk;
    FB_OFF  [W_PER_DW-1:0] fuse_blk_off_n;
    logic   [W_PER_DW-1:0] fuse_is_end, fuse_fmsk;

    // Only 10 may need merging
    assign mer_blk_off_n[0]     = blk_off_n[0];
    assign mer_blk_off_n[1][0]  =
        merge_off(
            blk_off_n[1][0], fuse_blk_off_n,
            fmsk     [1][0], fuse_fmsk
        );
    assign mer_blk_off_n[1][1]  = blk_off_n[1][1];

    assign mer_is_end[0]        = is_end[0];
    assign mer_is_end[1][0]     = is_end[1][0] | fuse_is_end;
    assign mer_is_end[1][1]     = is_end[1][1];

    assign mer_fmsk[0]          = fmsk[0];
    assign mer_fmsk[1][0]       = fmsk[1][0] | fuse_fmsk;
    assign mer_fmsk[1][1]       = fmsk[1][1];
    always_comb begin
        unique case (1'b1)
        merge_l0: begin
            fuse_blk_off_n  = blk_off_n [0][0];
            fuse_is_end     = is_end    [0][0];
            fuse_fmsk       = fmsk      [0][0];
        end

        merge_l1: begin
            fuse_blk_off_n  = blk_off_n [0][1];
            fuse_is_end     = is_end    [0][1];
            fuse_fmsk       = fmsk      [0][1];
        end

        default: begin
            fuse_blk_off_n  = '0;
            fuse_is_end     = '0;
            fuse_fmsk       = '0;
        end
        endcase
    end


    logic e0, e1;
    logic b0, b1;
    assign e0 = merge_l0;
    assign b0 = 0;

    always_comb begin
        e1 = merge_l0 | bhe00 | merge_l1;

        unique case (1'b1)
        merge_l0: begin
            // case 1:  bhe10 -> cant issue 2 (dont care)
            // case 2: ~bhe10 -> e1=1, b1=1
            // e1 = 1;
            b1 = 1;
        end

        ~merge_l0 &  bhe00: begin
            // e1 = 1;
            b1 = 0;
        end

        ~merge_l0 & ~bhe00 & ~merge_l1: begin
            // e1 = 0;
            b1 = 1;
        end

        ~merge_l0 & ~bhe00 &  merge_l1: begin
            // e1 = 1;
            b1 = 0;
        end

        default: begin // impossibles
            b1 = 1'bx;
        end
        endcase
    end


    assign ixq_out_dat[0] = '{
        dw      : dws           [e0][b0],
        off     : mer_blk_off_n [e0][b0],
        fmsk    : mer_fmsk      [e0][b0],
        is_end  : mer_is_end    [e0][b0]
    };

    assign ixq_out_dat[1] = '{
        dw      : dws           [e1][b1],
        off     : mer_blk_off_n [e1][b1],
        fmsk    : mer_fmsk      [e1][b1],
        is_end  : mer_is_end    [e1][b1]
    };

    /* Resource requests
    reqi = if we wish to emit i+1 dws, what resources are required?

    CAVEAT: This works on output dw granularities, and conservatively assumes
    a dw cannot be emitted unless ALL of its requests are satisfied. Technically, however,
    we can emit partially filled dw's that only satisfy a subset of the requirements.
    We do not consider these because they will probably not improve throughput much. 
    e.g.
    Let ftq_in_vld_scnt == 2, ixq_in_rdy_scnt == 1, rrb_in_rdy_scnt == *1*,
    and we have a (!case.inbuf & merge_l0 & bhe10) case.

    We can emit at most 1 dw, and the full dw (i.e. WITH l10 merged in) will require
    2 buffer slots, which is more than is available. However, if we skip the merge,
    we can emit a dw containing ONLY the l00 line. (the benefits of doing this
    are doubtful */

    struct packed {
        logic [NUM_DW-1:0] req_vld;// req_vld[i] = can we emit i+1 dw's at all?
        logic [NUM_DW-1:0] gnt;    // gnt[i] = are we granted to emit i+1 dw's?


        logic [NUM_DW-1:0][NUM_FTQ-1:0] req_rr_buf_actual;

        struct packed {
            logic [NUM_FTQ-1:0] ixq; // req_req[i].ixq is hardcoded (bits [i:0] are set)
            logic [NUM_FTQ-1:0] rr_buf;
            logic ftq1;
        } [NUM_DW-1:0] req_res;

        struct packed {
            logic [NUM_FTQ-1:0] ixq;
            logic [NUM_FTQ-1:0] rr_buf;
            logic ftq1;
        } rdy_res;
    } ctl; // control struct

    assign ctl.req_vld[0] = ftq_in_vld_scnt != 0;
    // do not permit merges if ft1 is not in window yet
    assign ctl.req_vld[1] = ftq_in_vld_scnt[1]
        ? ~(merge_l0 & bhe10)
        : (ftq_in_vld_scnt != 0) & ~bhe00 & ~merge_l1;

    assign ctl.req_res[0].ixq = 2'b01;
    assign ctl.req_res[1].ixq = 2'b11;

    // Which buf slots do we NEED to write to emit at all?
    assign ctl.req_res[0].rr_buf[0] = ~cur.inbuf | (adv_bidx[0] & ftq_in_vld_scnt[1]);
    assign ctl.req_res[0].rr_buf[1] = ~cur.inbuf & (adv_bidx[0] & ftq_in_vld_scnt[1]);
    assign ctl.req_res[1].rr_buf[0] = ~cur.inbuf | (adv_bidx[1] & ftq_in_vld_scnt[1]);
    assign ctl.req_res[1].rr_buf[1] = ~cur.inbuf & (adv_bidx[1] & ftq_in_vld_scnt[1]);

    // What buf slots must we write to qualify as fully in buf?
    assign ctl.req_rr_buf_actual[0][0] = ~cur.inbuf | adv_bidx[0];
    assign ctl.req_rr_buf_actual[0][1] = ~cur.inbuf & adv_bidx[0];
    assign ctl.req_rr_buf_actual[1][0] = ~cur.inbuf | adv_bidx[1];
    assign ctl.req_rr_buf_actual[1][1] = ~cur.inbuf & adv_bidx[1];

    // And which of those slots can we actually write?
    logic [1:0] can_buf_write;
    assign can_buf_write[0] = ~cur.inbuf | ftq_in_vld_scnt[1];
    assign can_buf_write[1] = ftq_in_vld_scnt[1];

    // Do we need ftq1 visible to emit?
    assign ctl.req_res[0].ftq1  = adv_bidx[0] & (aft_bidx[0] | adv_blk[0]);
    assign ctl.req_res[1].ftq1  = adv_bidx[1] & (aft_bidx[1] | adv_blk[1]);

    assign ctl.rdy_res.ixq[0]   = ixq_in_rdy_scnt != 0;
    assign ctl.rdy_res.ixq[1]   = ixq_in_rdy_scnt[1];
    assign ctl.rdy_res.rr_buf[0]= rrb_in_rdy_scnt != 0;
    assign ctl.rdy_res.rr_buf[1]= rrb_in_rdy_scnt[1];
    assign ctl.rdy_res.ftq1     = ftq_in_vld_scnt[1];

    generate
    for (genvar b = 0; b < NUM_DW; ++b) begin
        assign ctl.gnt[b] = !(|(ctl.req_res[b] & ~ctl.rdy_res));
    end
    endgenerate

    logic  iss_any; // can emit a dw?
    logic  iss_idx; // index of last emitted dw, if any
    assign iss_any = |(ctl.req_vld & ctl.gnt);
    assign iss_idx = ctl.req_vld[1] & ctl.gnt[1];

    assign rrb_out_dat[0] = cur.inbuf ? ftq_in_dat[1] : ftq_in_dat[0];
    assign rrb_out_dat[1] = ftq_in_dat[1];
    always_comb begin

        /*FIXME:
        We may actually request up to 3 buffer slots per cycle
        ftq 0 is !inbuf AND adv_base == 2

        Actually maybe this is fine. inbuf is zeroed when adv_base_v == 2.
        We don't even access to the 3rd ftq entry this cycle, so we will never
        be able to push it to the reread queue.
        */

        ixq_out_wen_cnt =
            !iss_any ? 0 :
            iss_idx ? 2 : 1;

        ftq_out_ren_cnt =
            (!iss_any || !adv_bidx[iss_idx]) ? 0 :
            aft_bidx[iss_idx] ? 2 : 1;

        rrb_out_wen_cnt =
            !iss_any ? 0 : $countones(ctl.req_res[iss_idx].rr_buf & ctl.rdy_res.rr_buf);
    end

    WADDR [NUM_FTQ-1:0] base_n;
    assign base_n[0] = ftq_in_dat[0].base_n;
    assign base_n[1] = ftq_in_dat[1].base_n;

    logic   basv, blkv;
    assign  basv = aft_bidx [iss_idx];
    assign  blkv = aft_blk  [iss_idx];

    always_ff @(posedge clock) begin
        if (reset)
`ifndef PC_GEN_TEST_MODE
            cur <= '{
                off : off_rst,
                base: base_rst,
                inbuf:inbuf_rst
            };
`else
            cur <= reset_val;
`endif
        else if (flush)
            cur <= '{
                off  : flush_fb_off,
                base : flush_fb_base,
                inbuf: 0
            };

        else if (iss_any) begin
            if (adv_bidx[iss_idx])
                cur.base    <= base_n[basv];

            if      (adv_blk [iss_idx])
                cur.off <= pos_blk_off[adv_bidx[iss_idx]][blkv];
            else if (adv_bidx[iss_idx])
                cur.off <= '0;

            if (iss_any)
                if (adv_bidx[iss_idx] && basv)
                    cur.inbuf   <= 0;
                else
                    cur.inbuf   <= !(|(ctl.req_rr_buf_actual[iss_idx] & ~(can_buf_write & ctl.rdy_res.rr_buf)));
        end

    end


`ifdef FORMAL
    always_ff @(posedge clock) begin
        if (!reset) begin
            for (int e = 0; e < NUM_FTQ; ++e)
                assert(!(|is_end_flat[e]) | $onehot(is_end_flat[e])) else $fatal;

            if (iss_any) begin
                // adv_blk is high IFF we do not advance 2 bases
                assert(adv_blk[iss_idx] ? !(adv_bidx[iss_idx] && basv) : 1) else $fatal;
                assert((adv_bidx[iss_idx] && basv) ? !adv_blk[iss_idx] : 1) else $fatal;
            end
        end

    end
`endif


`ifdef DEBUG
    task print_pc_gen;
        // $display("ftq_in_dat[*].off: [%d, %d]",
        //     ftq_in_dat[0].off,
        //     ftq_in_dat[1].off,
        // );

        $display("\n\n\nFOGET: base: %d, off: %d, inbuf: %b", cur.base, cur.off, cur.inbuf);
        $display("come the fuckon: %b %d,",
            adv_bidx[iss_idx] & ftq1_vld,
            1 + adv_bidx[iss_idx] & ftq1_vld
        );

        $display("ctl.rdy_res: {ixq= %b, rr_buf %b}",
            ctl.rdy_res.ixq,
            ctl.rdy_res.rr_buf
        );

        $display("ctl.req_rr_buf_actual: %b, %b",
            ctl.req_rr_buf_actual[0],
            ctl.req_rr_buf_actual[1]
        );

        $display("ctl.req[0]: vld=%b {ixq= %b, rr_buf %b} gnt=%b",
            ctl.req_vld[0],
            ctl.req_res[0].ixq,
            ctl.req_res[0].rr_buf,
            ctl.gnt[0]
        );

        $display("ctl.req[1]: vld=%b {ixq= %b, rr_buf %b} gnt=%b",
            ctl.req_vld[1],
            ctl.req_res[1].ixq,
            ctl.req_res[1].rr_buf,
            ctl.gnt[1]
        );

        $display("base_n[0]: %d, base_n[1]: %d", base_n[0], base_n[1]);
        $display("iss_idx: %b, bidx[adv: %b, aft: %b], blk[av: %b, aft: %b]",
            iss_idx,
            adv_bidx[iss_idx],
            aft_bidx[iss_idx],
            adv_blk[iss_idx],
            aft_blk[iss_idx]
        );
        $display("0-bidx: [adv: %b, aft: %b], 1-bidx: [adv: %b, aft: %b]",
            adv_bidx[0],
            aft_bidx[0],
            adv_bidx[1],
            aft_bidx[1]
        );
        $display("0-blk:  [adv: %b, aft: %b], 1-blk:  [adv: %b, aft: %b]",
            adv_blk[0],
            aft_blk[0],
            adv_blk[1],
            aft_blk[1]
        );
        for (int i = 0; i < 4; ++i) begin
            logic x, y;
            x = i / 2;
            y = i % 2;
            $display("pos_blk_off[%d][%d]: %d",
                x,
                y,
                pos_blk_off[x][y]
            );
        end

        $display("(e0, b0) = (%b, %b), (e1, b1) = (%b, %b)", e0, b0, e1, b1);
        $display("merge_l0: %b, merge_l1: %b", merge_l0, merge_l1);
        $display("bhe00: %b, bhe01: %b, bhe10: %b, bhe11: %b", bhe00, bhe01, bhe10, bhe11);

        $display("mer fmsk: [%b, %b]",
            mer_fmsk[0],
            mer_fmsk[1]
        );
        $display("mer is_end: [%b, %b]",
            mer_is_end[0],
            mer_is_end[1]
        );

        $display("nal_off_n: [[%d, %d, %d, %d, %d], [%d, %d, %d, %d, %d]]",
            nal_off_n[0][0],
            nal_off_n[0][1],
            nal_off_n[0][2],
            nal_off_n[0][3],
            nal_off_n[0][4],
            nal_off_n[1][0],
            nal_off_n[1][1],
            nal_off_n[1][2],
            nal_off_n[1][3],
            nal_off_n[1][4]
        );

        // $display("nal_is_end: %b", nal_is_end);

        $display("ftq_in_vld_scnt: %d", ftq_in_vld_scnt);
        $display("ftq[0]: base_woff: %b, align_msk: %b, fmsk: %b, off_n: [%d, %d, %d, %d, %d], is_end_flat: %b",
            base_woff[0],
            align_msk[0],
            fmsk_flat[0],
            off_n[0][0],
            off_n[0][1],
            off_n[0][2],
            off_n[0][3],
            off_n[0][4],
            is_end_flat[0]
        );

        $display("ftq[1]: base_woff: %b, align_msk: %b, fmsk: %b, off_n: [%d, %d, %d, %d, %d], is_end_flat: %b",
            base_woff[1],
            align_msk[1],
            fmsk_flat[1],
            off_n[1][0],
            off_n[1][1],
            off_n[1][2],
            off_n[1][3],
            off_n[1][4],
            is_end_flat[1]
        );

        $display("ftq_out: ren_cnt: %d",
            ftq_out_ren_cnt
        );

        $display("ixq_out: wen_cnt = %d, off = [[%d, %d], [%d, %d]], fmsk = [%b, %b], is_end = [%b, %b], dw = [%d, %d]",
            ixq_out_wen_cnt,
            ixq_out_dat[0].off[0],
            ixq_out_dat[0].off[1],
            ixq_out_dat[1].off[0],
            ixq_out_dat[1].off[1],

            ixq_out_dat[0].fmsk,
            ixq_out_dat[1].fmsk,

            ixq_out_dat[0].is_end,
            ixq_out_dat[1].is_end,

            ixq_out_dat[0].dw,
            ixq_out_dat[1].dw
        );

        $display("rrb_out: wen_cnt = %d, [{id %4d, base_n: %d, ft: %b, off: %d}, {id: %4d, base_n: %d, ft: %b, off: %d}]\n",
            rrb_out_wen_cnt,
`ifdef PC_GEN_TEST_MODE
            rrb_out_dat[0].id,
`else
            0,
`endif
            rrb_out_dat[0].base_n,
            rrb_out_dat[0].ft,
            rrb_out_dat[0].off,
`ifdef PC_GEN_TEST_MODE
            rrb_out_dat[1].id,
`else
            0,
`endif
            rrb_out_dat[1].base_n,
            rrb_out_dat[1].ft,
            rrb_out_dat[1].off
        );

        $display("adv_bidx: [%b, %b] |||| aft_bidx: [%b, %b]",
            adv_bidx[0],
            adv_bidx[1],
            aft_bidx[0],
            aft_bidx[1]
        );

        $display("adv_blk: [%b, %b] |||| aft_blk: [%b, %b]",
            adv_blk[0],
            adv_blk[1],
            aft_blk[0],
            aft_blk[1]
        );

        // $display("adv_blk: [%d, %d, %d] -> %d",
        //     adv_blk[0],
        //     adv_blk[1],
        //     adv_blk[2],
        //     adv_blk_v
        // );

        $display("pos_blk_off: [\n[%d, %d],\n[%d, %d]] -> %d",
            pos_blk_off[0][0],
            pos_blk_off[0][1],
            // pos_blk_off[0][2],
            pos_blk_off[1][0],
            pos_blk_off[1][1],
            // pos_blk_off[1][2],
            0
            // pos_blk_off[adv_base_v][adv_blk_v]
        );

        // $display("base_woff: %b, %b", base_woff[0], base_woff[1]);
        // $display("ixq_out_dw [%d, %d]", ixq_out_dw[0], ixq_out_dw[1]);
        // $display("ixq_out_fmsk [%b, %b]", ixq_out_fmsk[0], ixq_out_fmsk[1]);
        // $display("is_end_flat: %b", dut.is_end_flat);
        // $display("align_msk: %b, fmsk: %b", dut.align_msk, dut.fmsk);
        // $display("%d %d %d %d %d",
        //     dut.nal_off_n[0][0],
        //     dut.nal_off_n[0][1],
        //     dut.nal_off_n[0][2],
        //     dut.nal_off_n[0][3],
        //     dut.nal_off_n[0][4]
        // );

        // $display("%b %b %b %b",
        //     dut.nal_is_end[0][0],
        //     dut.nal_is_end[0][1],
        //     dut.nal_is_end[0][2],
        //     dut.nal_is_end[0][3]
        // );
        // $display("off: %d %d", ftq_in_dat[0].off, ftq_in_dat[1].off);
        // $display("fmsk[0]: [%b]", dut.fmsk[0]);
        // $display("dws [%d, %d]", dut.dws[0][0], dut.dws[0][1]);
        // $display("o_dws [%d, %d]", dut.o_dws[0], dut.o_dws[1]);

    endtask
`endif

endmodule
