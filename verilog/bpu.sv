`include "sys_defs.svh"

/* Branch predictor unit (BPU):
generates PCs for decoupled fetch (experimental) */

/* TODO:
- scheme to squash speculatively generated fetch blocks?
See "5.3.1. L1 FTB Miss and L2 FTB Hit" in Reinman's paper "Optimizations Enabled..."
*/
module bpu (
    input   clock,
    input   reset,
    input   execute2complete_bru cbru_in,

    input   logic       i_uen,
    input   BPU_UPD_PKT i_udat,

    input   logic       i_ftq_rdy,
    output  logic       o_ftq_en,
    output  FTQ_ENTRY   o_ftq_dat
);
    logic flush;
    assign flush = cbru_in.flush;

    logic step;
    struct packed {
        logic[3:0]  off;    // in-FB offset
        WADDR       base;   // current FB/FTB base
    } cur, cur_n;
    assign cur_n.off = '0;

    struct packed {
        // fetch query
        WADDR       i_qry;

        logic       o_vld;
        FTB_ENTRY   o_tgt;

        // puq updates
        logic       i_uen;
        FTB_UPD_PKT i_udat;
    } uftb_io;

    struct packed {
        // fetch
        `CNT_TYPE(NUM_BR_SLOTS) wen_cnt;
        logic [NUM_BR_SLOTS-1:0]wpred, wshf_out;

        GHR_IDX base_n1;
        logic [GHR_LEN-1:0] rd_ghist;
    } ghr_io;

    struct packed {
        logic [NUM_BR_SLOTS-1:0] pred;
        logic [GHR_LEN-1:0] hash;
    } gshare_io;

    assign uftb_io.i_qry = cur.base;
    assign uftb_io.i_uen = i_uen;
    assign uftb_io.i_udat= '{
        base        : i_udat.base,
        fb_off      : i_udat.fb_off,
        take        : i_udat.take,
        tgt         : i_udat.tgt,

        md          : i_udat.md
    };

    uftb #(
        .NUM_LINES(16)
    ) uftb0 (
        .clock,
        .reset,

        .i_qry  (uftb_io.i_qry),

        .o_vld  (uftb_io.o_vld),
        .o_tgt  (uftb_io.o_tgt),

        .i_uen  (uftb_io.i_uen),
        .i_udat (uftb_io.i_udat)
    );

    logic [NUM_BR_SLOTS-1:0] pred;
    logic pred_any;
    `IDX_TYPE(NUM_BR_SLOTS) pred_idx;
    ffs #(
        .VECW(NUM_BR_SLOTS)
    ) ff_take (
        .i_vec(pred),
        .o_vld(pred_any),
        .o_idx(pred_idx)
    );

    logic [NUM_BR_SLOTS-1:0] in_ghr;
    always_comb begin
        FTB_ENTRY e;
        FTB_BR_SLOT slot;
        WADDR pc_flt, pc_jmp;
        logic leq0, leq1;
        `CNT_TYPE(NUM_BR_SLOTS) ghr_wvld_cnt;

        const FTB_MD1 COND_MD = '{
            cond : 1,
            call : 0,
            ret  : 0,
            jalr : 0
        };

        e = uftb_io.o_tgt;

        // ignore branches before the current FB-offset
        // cmp4(off, e.br_slot[0].off, eq0, lt0);
        // cmp4(off, e.br_slot[1].off, eq1, lt1);
        // leq0 = eq0 || lt0;
        // leq1 = eq1 || lt1;
        leq0 = cur.off <= e.br_slot[0].off;
        leq1 = cur.off <= e.br_slot[1].off;
        pred[0] =
            !e.br_slot[0].vld ? 0 :
            leq0 && gshare_io.pred[0];
            // leq0 && query_sc(e.br_slot[0].sc);
        pred[1] =
            !e.br_slot[1].vld ? 0 :
            leq1 && (!e.md1.cond || gshare_io.pred[1]);
            // leq1 && (!e.md1.cond || query_sc(e.br_slot[1].sc));
        if (!uftb_io.o_vld)
            pred = '0;

        in_ghr[0] =
            (!e.br_slot[0].vld || !leq0) ? 0 : 1;
        in_ghr[1] =
            (!e.br_slot[1].vld || !leq1) ? 0 :
            ~(pred_any & ~pred_idx);
        ghr_wvld_cnt = $countones(in_ghr);

        slot = e.br_slot[pred_idx];
        step = buf_io.i_rdy;


        if (!step || !uftb_io.o_vld)
            ghr_io.wen_cnt = 0;
        else
            ghr_io.wen_cnt = ghr_wvld_cnt;
        ghr_io.wpred = pred >> !leq0; // !leq0 is in_ghr[0] without the validity check
            /* FIXME: extremely hacky
            When the current fb off is BEYOND the 1st branch slot, then
            the first branch we can shift into the GHR is the 2nd branch slot. */

        pc_flt = cur.base + `UCAST_LEN(
            (e.end_off == 4'd15)
                ? 16
                : e.end_off + `UCAST_FIT(1),
            16
        );

        pc_jmp = slot.tgt;
        cur_n.base =
            !uftb_io.o_vld ? cur.base + `UCAST_FIT(16) :
            pred_any ? pc_jmp : pc_flt;

        buf_io.i_dat = '{
            base_n      : cur_n.base,
            // hash        : gshare_io.hash,

            ft          : !pred_any,
            pred_idx    : pred_idx,
            off         : 
                !uftb_io.o_vld ? 15 :
                pred_any ? slot.off : e.end_off,
            hit         : uftb_io.o_vld,
            
            slot        : '0, // filled below
            in_ghr      : in_ghr,
            ghr_base_n1 : ghr_io.base_n1,
            always_take : slot.always_take,
            md          : (pred_idx == 0) ? COND_MD : e.md1
        };

        for (int i = 0; i < NUM_BR_SLOTS; ++i) begin
            buf_io.i_dat.slot[i] = '{
                vld : e.br_slot[i].vld,
                off : e.br_slot[i].off
            };
        end
    end

    /*
    FIXME:
    - GHR temporarily commented out because none of our predictors rely on it yet
    - Q: How to pass ghr_base forward to FTQ? A:
    Each FTB_ENTRY / fetch block has 2 branch slots, so the FTQ_ENTRY will
    need to store at most 2 ghr_base's.
        A. Store only the initial ghr_base and compute the 2nd ghr_base on the fly
        (need to ensure it is equal the ghr_base fed into the GHR).
        B. Simply store both ghr_base's.
    
    Remember, any branch in the fetch block which do not occupy a branch slot is
    assumed "never taken" and do not require a branch slot, thus nor a ghr_base.
    They will only ever start receiving their own ghr_base if they are ever taken
    and added to a branch_slot.
    */
    logic [FH_LEN-1:0] fh, rd_fh;
    fhr #(
        .GHR_LEN    (GHR_LEN),
        .FH_LEN     (FH_LEN),

        .WPORTS     (NUM_BR_SLOTS)
    ) fhr0 (
        .clock,
        .reset,

        .flush,

        .qry_ghist  (ghr_io.rd_ghist),
        .rd_fh,

        .wen_cnt    (ghr_io.wen_cnt),
        .wshf_in    (ghr_io.wpred),
        .wshf_out   (ghr_io.wshf_out),

        .fh
    );

    ghr #(
        .DEPTH      (GHR_BUF_SZ),
        .GHR_LEN    (GHR_LEN),

        .WPORTS     (NUM_BR_SLOTS)
    ) ghr0 (
        .clock,
        .reset,

        .flush,
        .flush_take (cbru_in.take),
        .flush_idx  (cbru_in.flush_ghr_base),

        .wen_cnt    (ghr_io.wen_cnt),
        .wshf_in    (ghr_io.wpred),
        .wshf_out   (ghr_io.wshf_out),
        .base_n1    (ghr_io.base_n1),

        .ridx       (i_udat.ghr_base),
            /* FIXME: hacky fix. We want the history LEADING UP TO the branch––
            should not include the branch itself!! */
        .rd_ghist   (ghr_io.rd_ghist)
    );

    always_ff @(posedge clock) begin
        if (!reset)
            assert (fhr0.fh == fhr0.compute_fh(ghr0.ghist)) else $fatal;
    end

    // WADDR tmp;
    // assign tmp = i_udat.base - i_udat.fb_off;
    gshare gshare0 (
        .clock,
        .reset,

        .i_uen,
        // .i_uhash(rd_fh),
        .i_uhash(rd_fh ^ i_udat.base[FH_LEN-1:0]),
        .i_udat,

        // .i_hash (fh),
        .i_hash (fh ^ cur.base[FH_LEN-1:0]),
        .o_pred (gshare_io.pred)

    );


    struct packed {
        logic i_rdy;
        FTQ_ENTRY i_dat;
    } buf_io;

    logic o_buf_ftq_vld;
    ppln_skid #(
        .FLUSH_MODE (SKID_FLUSH_RESET),
        .WIDTH      ($bits(FTQ_ENTRY))
    ) buf_ftq (
        .clock,
        .reset,
        .flush,
        .clmsk  ('0), // unused

        .i_vld (step), // FIXME: should this be step without the buf_io.i_rdy component?
        .i_rdy (buf_io.i_rdy),
        .i_msk ('0),
        .i_dat (buf_io.i_dat),

        .o_vld (o_buf_ftq_vld),
        .o_rdy (i_ftq_rdy),
        .o_msk (),
        .o_dat (o_ftq_dat)
    );

    assign o_ftq_en = o_buf_ftq_vld && i_ftq_rdy;

    always_ff @(posedge clock) begin
        if (reset)
            cur <= '0;
        else if (flush)
            cur <= '{
                base: cbru_in.flush_fb_base,
                off : cbru_in.flush_fb_off
            };
        else if (step)
            cur <= cur_n;
    end

`ifdef DEBUG
    task print_bpu;
        $display(">> bpu");
        $display("(cur.base: %d, off: %0d, pred: [%b, %b]), step: %b, buf_rdy: %b, ftq_rdy: %b",
            cur.base,
            off,
            pred[0],
            pred[1],
            step,
            buf_io.i_rdy,
            i_ftq_rdy
        );

        $display("<< bpu");
    endtask

    task automatic print_udat;
        $display("base: %d, pred_fh: %b, pred: %b, wpred: %b", cur.base, fh, gshare_io.pred, pred);
        // if (i_uen)
        //     $display("base: %d, off: %d, pc: %2d, take: %b (hist: %b) edu: %b",
        //         i_udat.base,
        //         i_udat.fb_off,
        //         i_udat.base + i_udat.fb_off,
        //         i_udat.take,
        //         ghr_io.rd_ghist,
        //         i_udat.en_dir_update
        //     );
    endtask

`endif

endmodule