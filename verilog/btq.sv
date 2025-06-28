`include "sys_defs.svh"

typedef struct packed {
`ifdef DEBUG
    BMASK   b1hot;
    BRANCH_RESO_CODE reso;
`endif
    WADDR   PC;
    logic   is_tail;
        /*  In BPU, if hit in FTB, is the offset of this branch greater than or equal
        to the offset of the branch in the tail slot / br1, if any? */
    logic   [3:0] off; // offset in fb (if taken, equals offset in FTQ_ENTRY)

    logic   rslv; // resolved? 0: take, tgt are predictions, 1: " are real values
    logic   take;
    WADDR   tgt;
        // NOTE: We used to have separate pred, pred_tgt fields.

    logic   always_take;
        /* During retire-time update, this is sent to the direction predictors,
        and not the FTB. We will use "take" to update the always_take in-place
        in the FTB. */
    FTB_MD1 md;

    logic   hit;        // hit an entry with base in FTB?
    logic   hit_slot;   // hit a slot in entry? (valid only if hit)
    logic   slot_idx;   // hit a slot in entry? (valid only if hit)
    logic[1:0]in_ghr;
    // logic   [GHR_LEN-1:0]   hash;       // gshare hash index
    GHR_IDX ghr_base;
} BTQ_ENTRY;


/* Branch target queue */
module btq #(
    parameter BTQ_SZ = BTQ_SZ,  // num elements
    parameter N=N
) (
    input  clock,
    input  reset,
    // complete (write)
    input  execute2complete_bru cbru_in,

    // prf re-read
    input  execute2btq  ex_in,
    output btq2execute  ex_out,

    // dispatch (alloc snapshot)
    input  rename2snap_bus snap_in,

    // fetch
    input  fetch2btq    f_in,
    output btq2fetch    f_out
);
    logic flush;
    BMASK clmsk;
    assign flush = cbru_in.flush;
    assign clmsk = cbru_in.clmsk;

    localparam NUM_FPORTS = N; // fetch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = NUM_FU_BRU; // complete ports (*OUT-OF-ORDER*)

    BTQ_ENTRY [BTQ_SZ-1:0]      state;
    `IDX_TYPE(BTQ_SZ)       head, tail, snap;
    `CNT_TYPE(BTQ_SZ)       used, free;
    `CNT_TYPE(NUM_RPORTS)   btq_vld_scnt, rd_en_cnt;

    logic [NUM_RPORTS:0][`IDX_SIZE(BTQ_SZ)-1:0] r_idxs_n;
    logic [NUM_FPORTS:0][`IDX_SIZE(BTQ_SZ)-1:0] f_idxs_n;

`ifdef DEBUG
    int num_branches_retired;
    int num_branches_mispred [$];

    logic [NUM_RPORTS-1:0] new_branches_mispred;
`endif

    ring_ctr #(
        .DEPTH(BTQ_SZ),
        .RPORTS(NUM_RPORTS),
        .WPORTS(NUM_FPORTS),
        .FLUSH_MODE(FIFO_FLUSH_SNAP_TAIL)
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,
        .flush_snap (snap),

        .rd_en_cnt  (rd_en_cnt),
        .wr_en_cnt  (f_in.wen_cnt),

        .head,
        .tail,
        .rd_idxs_n  (r_idxs_n),
        .wr_idxs_n  (f_idxs_n),

        .used,
        .free,
        .used_scnt(btq_vld_scnt),
        .free_scnt(f_out.rdy_scnt)
    );

    general_snaps #(
        .WIDTH(`IDX_SIZE(BTQ_SZ))
    ) btq_tails (
        .clock,

        .rmsk   (clmsk),
        .rdat   (snap),

        .wen    (snap_in.snap_en),
        .wmsk   (snap_in.b1hot_n),
        .wdat   (snap_in.btq_tail)
    );

    logic [NUM_RPORTS-1:0] nret;
    logic [NUM_RPORTS:0][`CNT_SIZE(NUM_RPORTS)-1:0] nret_prefix_cnt;
    generate
    for (genvar i = 0; i < NUM_RPORTS; ++i) begin
        assign nret[i] = !state[r_idxs_n[i]].md.ret; // nret = not a return instruction
    end
    endgenerate

    compactor #(
        .REQW(NUM_RPORTS),
        .GNTW(NUM_RPORTS)
    ) comp_nret (
        .req        (nret),
        .prefix_cnt (nret_prefix_cnt)
    );


    logic puq_empty;
    `CNT_TYPE(NUM_RPORTS) puq_rdy_scnt;
    BPU_UPD_PKT [NUM_RPORTS-1:0]puq_enq_raw,
                                puq_enq_flt; // ret's filtered out (FIXME: probably dont want to filter out ret's to FTB)

    // btq retire window
    BTQ_ENTRY   [NUM_RPORTS-1:0] rdat;
    logic       [NUM_RPORTS-1:0] rcpl;
    generate
    for (genvar i = 0; i < NUM_RPORTS; ++i) begin
        assign rdat[i] = state[r_idxs_n[i]];
        assign rcpl[i] = rdat[i].rslv;
    end
    endgenerate

    logic ncpl_any; // any unresolved/incomplete in retire window?
    `IDX_TYPE(NUM_RPORTS) ncpl_idx; // first index in retire window that is not resolved
    ffs #(
        .VECW(NUM_RPORTS)
    ) ff_end (
        .i_vec(~rcpl),
        .o_vld(ncpl_any),
        .o_idx(ncpl_idx)
    );

    assign rd_en_cnt = `MIN(
        `MIN(btq_vld_scnt, puq_rdy_scnt),
        ncpl_any ? ncpl_idx : `UCAST_FIT(NUM_RPORTS)
    );

    always_comb begin
        // handle retires (btq->puq)
        for (int i = 0; i < NUM_RPORTS; ++i) begin
            BTQ_ENTRY cur;
            cur = rdat[i];
`ifdef DEBUG
            new_branches_mispred[i] =
                cur.reso.pred != cur.reso.take  ? 1 :
                cur.reso.pred                   ? !cur.reso.corr_tgt : 0;
`endif

            puq_enq_raw[i] = '{
                base    : cur.PC - cur.off,
                fb_off  : cur.off,
                take    : cur.take,
                tgt     : cur.tgt,
                always_take : cur.always_take && cur.take,
                    /* Why update always_take here instead of during complete?
                    Updating always_take requires reading the existing value.
                    We do a read during retire, but not during complete. */
                md      : cur.md,

                en_dir_update : cur.hit && cur.hit_slot,
                slot_idx: cur.slot_idx,
                ghr_base: cur.ghr_base
                    + 1'b1 // skip the current branch (gets branch history LEADING UP to the branch)
                    + (cur.slot_idx & cur.in_ghr[0])

                    /* Why the two "+" terms are needed:

                    >> Begin: Aside
                        We keep TWO 2-bit saturating counters in every gshare row:
                        bits[1:0] → slot-0 branch in this UFTB entry
                        bits[3:2] → slot-1 branch in this UFTB entry
                        
                        The predictor **looks up only one row** per fetch block, then
                        reads both 2-bit counters to predict the two branches.
                    << End : Aside

                    A. [[ +1 ]]
                        - universal: we want the history that ends *before* the branch we're retiring.
                    
                    B. [[ +(slot_idx & in_ghr[0]) ]]
                        - slot-1 **only if** slot-0 actually entered the GHR this cycle

                        After the A. +1 we are on slot-0's bit. We must advance **one more**
                        step so that slot-1 trains the *same* PHT row as slot-0, just a different
                        2-bit slice/counter.

                        Without this extra hop the second update lands in the next
                        gshare row; the BPU never looks at that row, so slot-1's
                        counter is trained but never read -> accuracy collapses.
                     */
                // hash    : cur.hash
            };

        end

        puq_enq_flt = '0;
        for (int i = 0; i < NUM_RPORTS; ++i)
            puq_enq_flt[nret_prefix_cnt[i]] = puq_enq_raw[i];

        // handle fetch (outs)
        f_out.bpu_uen   = !puq_empty & !flush;
            /* GHR has only 1 barrel shift port (rd_ghist), and flush takes
            precedence over retire-time BPU updates */
        f_out.btq_idxs_n= f_idxs_n;

        // handle reads (execute)
        for (int i = 0; i < NUM_FU_BRU; ++i) begin
            BTQ_ENTRY cur;
            cur = state[ex_in.btq_ridx[i]];
            ex_out.is_tail  [i] = cur.is_tail;
            ex_out.pred     [i] = cur.take;
            ex_out.pred_tgt [i] = cur.tgt;
            ex_out.fb_off   [i] = cur.off;
            ex_out.ghr_base [i] = cur.ghr_base;
        end
    end

    localparam PUQ_SZ = 3;
    fifo #(
        .DEPTH(PUQ_SZ),
        .WIDTH($bits(BPU_UPD_PKT)),
        .NUM_RPORTS(1),
        .NUM_WPORTS(NUM_RPORTS),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(200)
    ) puq ( // predictor update queue
        .clock      (clock),
        .reset      (reset),

        // >> unused inputs
        .flush      ('0),
        .flush_snap ('0),
        .clmsk      ('0),
        .wr_bmask   ('0),
        // << unused inputs

        .wr_en_cnt  (nret_prefix_cnt[rd_en_cnt]),
        .wr_data    (puq_enq_flt),
        .rd_en_cnt  (f_out.bpu_uen),
        .rd_data    (f_out.bpu_udat),
        .free_scnt  (puq_rdy_scnt),
        .used_scnt  (),
        .empty      (puq_empty)
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            state   <= '0;
        end else begin
            if (f_in.wen_cnt > free)
                $error("BTQ overflow!");
            if (rd_en_cnt > used)
                $error("BTQ underflow!");

            // handle complete (ins)
            for (int i = 0, int idx = 0; i < NUM_CPORTS; ++i) begin
                idx = cbru_in.btq_idx[i];
                if (!cbru_in.en[i])
                    continue;

                state[idx].rslv <= 1;
                state[idx].tgt  <= cbru_in.tgt[i];
                state[idx].take <= cbru_in.take[i];
`ifdef DEBUG
                state[idx].b1hot<= '0;
                state[idx].reso <= cbru_in.reso[i];
`endif
            end

`ifdef DEBUG
            // mark alloc'd b1hot (debug only)
            for (int i = 0; i < N; ++i) begin
                if (!snap_in.snap_en[i])
                    continue;
                state[snap_in.btq_idx[i]].b1hot <= snap_in.b1hot_n[i];
            end
`endif

            // handle fetch (ins)
            for (int i = 0, int idx = 0; i < NUM_FPORTS; ++i) begin
                idx = f_idxs_n[i];
                if (i >= f_in.wen_cnt)
                    continue;

                state[idx] <= '{
`ifdef DEBUG
                    b1hot   : '0,
                    reso    : '0,
`endif
                    PC      : f_in.PC[i],
                    is_tail : f_in.is_tail[i],
                    off     : f_in.off[i],

                    rslv    : 0,
                    take    : f_in.pred[i],
                    tgt     : f_in.pred_tgt[i],

                    always_take : f_in.always_take[i],
                    md      : f_in.md[i],

                    hit     : f_in.hit[i],
                    hit_slot: f_in.hit_slot[i],
                    slot_idx: f_in.slot_idx[i],
                    in_ghr  : f_in.in_ghr[i],
                    // hash    : f_in.hash[i],
                    ghr_base: f_in.ghr_base[i]
                };
            end
        end
    end


`ifdef DEBUG
    localparam branch_bin_sz = 200;
    always_ff @(posedge clock) begin
        if (reset) begin
            num_branches_retired <= 0;

        end else begin
            int num_bins;
            num_bins = num_branches_mispred.size;

            num_branches_retired <= num_branches_retired + rd_en_cnt;

            for (int i = 0; i < rd_en_cnt; ++i) begin
                int bin;
                bin = (num_branches_retired + i) / branch_bin_sz;
                if (bin >= num_bins)
                    num_branches_mispred.push_back(0);

                num_branches_mispred[$] += new_branches_mispred[i];
            end

        end
    end
    
    task print_pred_stats;
        int num_bins;
        num_bins = num_branches_mispred.size;
        $display("num_bins: %d", num_bins);
        $display("num_branches_retired: %d", num_branches_retired);
        for (int i = 0; i < num_bins; ++i)
            $display("%4d-%4d: %4d", branch_bin_sz*i, branch_bin_sz*(i+1), num_branches_mispred[i]);
    endtask

    task print_btq;
        logic [BTQ_SZ-1:0] btq_vld;

        $display(">> BTQ >>");
        $display("head: %d, tail: %d, used: %d, free: %d", head, tail, used, free);
        $display("flush: %b, flush_snap: %2d, clmsk: %b", flush, snap, clmsk);
        $display("rd_en_cnt: %2d, wr_en_cnt: %2d", rd_en_cnt, f_in.wen_cnt);
        btq_vld = '0;
        for (int cnt = 0; cnt < used; ++cnt)
            btq_vld[(head + cnt) % BTQ_SZ] = 1;

        for (int i = 0; i < BTQ_SZ; ++i) begin
            if (!btq_vld[i]) begin
                $display("BTQ[%2d]:", i);
                continue;
            end

            $write("BTQ[%2d]: {pc: %d (fb_base: %d, off: %d)}, {rslv: %b take: %b, tgt: %x}, ghr_base: %2d, hit & hit_slot: %b, slot_idx: %b, at: %b, md: %b, is_tail: %b ",
                i,
                state[i].PC,
                state[i].PC - state[i].off,
                state[i].off,
                state[i].rslv,
                state[i].take,
                state[i].tgt,
                state[i].ghr_base,
                // state[i].hash,
                state[i].hit & state[i].hit_slot,
                state[i].slot_idx,
                state[i].always_take,
                state[i].md,
                state[i].is_tail
            );

            if(|state[i].b1hot)
                $display("b1hot: %b", state[i].b1hot);
            else
                $display("b1hot:");
        end

        $display("");
        for (int i = 0; i < BMASK_LEN; ++i) begin
            `IDX_TYPE(BTQ_SZ) tail;
            tail = btq_tails.snaps[i];
            $display("btq_tail[%8b]: %2d", 1 << i, tail);
        end

        for (int i = 0; i < NUM_FU_BRU; ++i) begin
            $display("cbru_in[%0d]: en: %b, btq_idx: %d, take: %b, tgt: %x",
                i,
                cbru_in.en[i],
                cbru_in.btq_idx[i],
                cbru_in.take[i],
                cbru_in.tgt[i]
            );
        end

        $display("<< BTQ <<");
    endtask

`endif
endmodule
