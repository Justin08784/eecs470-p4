`include "sys_defs.svh"
typedef struct packed {
    WADDR       base;   // current FB/FTB base
    logic [3:0] off;    // in-FB offset
} FB_POS;

typedef struct packed {
    `CNT_TYPE(NUM_BR_SLOTS) wen_cnt;
    logic [NUM_BR_SLOTS-1:0]wshf_in;
} s1_to_ghr;

typedef struct packed {
    GHR_IDX base_n1;
} ghr_to_s1;

module pred_s1 (
    input   clock,
    input   reset,

    input   logic   i_uen,
    input   BPU_UPD_PKT i_udat,

    input   FB_POS  i_pos,

    output  s1_to_ghr  ghr_out,
    input   ghr_to_s1  ghr_in,

    output  FB_POS  o_pos,
    input   logic   o_rdy,
    output  logic   o_wen,
    output  FTQ_ENTRY   o_dat
);
    logic       hit;
    FTB_ENTRY   row;
    FTB_BR_SLOT slot;
    FTB_UPD_PKT uftb_udat;
    assign uftb_udat = '{
        base    : i_udat.base,
        fb_off  : i_udat.fb_off,
        take    : i_udat.take,
        tgt     : i_udat.tgt,

        md      : i_udat.md
    };

    uftb #(
        .NUM_LINES(16)
    ) uftb0 (
        .clock,
        .reset,

        .i_qry  (i_pos.base),

        .o_vld  (hit),
        .o_tgt  (row),

        .i_uen  (i_uen),
        .i_udat (uftb_udat)
    );

    logic [1:0] in_win;
    assign in_win[0] = i_pos.off <= row.br_slot[0].off;
    assign in_win[1] = i_pos.off <= row.br_slot[1].off;

    logic [1:0] pred;
    logic pred_any, pred_idx;
    assign pred[0] = (hit & row.br_slot[0].vld & in_win[0])
        &  query_sc(row.br_slot[0].sc);
    assign pred[1] = (hit & row.br_slot[1].vld & in_win[1])
        & (query_sc(row.br_slot[1].sc) | ~row.md1.cond);
    assign pred_any = |pred;
    assign pred_idx = ~pred[0] & pred[1];

    logic [1:0] in_ghr;
    assign in_ghr[0] = row.br_slot[0].vld & in_win[0];
    assign in_ghr[1] = row.br_slot[1].vld & in_win[1] & ~(pred_any & ~pred_idx);

    assign slot = row.br_slot[pred_idx];
    assign o_wen= o_rdy;

    assign ghr_out.wen_cnt = (o_wen & hit) ? $countones(in_ghr) : 0;
    assign ghr_out.wshf_in = pred >> ~in_win[0];

    WADDR pc_ft, pc_jmp;
    assign pc_ft = i_pos.base + `UCAST_LEN(
        (row.end_off == 4'd15)
            ? 16
            : row.end_off + `UCAST_FIT(1),
        16
    );
    assign pc_jmp = slot.tgt;
    assign o_pos = '{
        base :
            !hit    ? i_pos.base + `UCAST_FIT(16) :
            pred_any? pc_jmp : pc_ft,

        off : '0
    };


    localparam FTB_MD1 COND_MD = '{
        cond : 1,
        call : 0,
        ret  : 0,
        jalr : 0
    };
    always_comb begin
        o_dat = '{
            base_n      : o_pos.base,

            ft          : ~pred_any,
            pred_idx    : pred_idx,
            off         : 
                ~hit    ? 15 :
                pred_any? slot.off : row.end_off,
            hit         : hit,
            
            slot        : '0, // filled below
            in_ghr      : in_ghr,
            ghr_base_n1 : ghr_in.base_n1,
            always_take : slot.always_take,
            md          : (pred_idx == 0) ? COND_MD : row.md1
        };

        for (int i = 0; i < NUM_BR_SLOTS; ++i) begin
            o_dat.slot[i] = '{
                vld : row.br_slot[i].vld,
                off : row.br_slot[i].off
            };
        end
    end
endmodule;

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

    input   btq2bpu     btq_in,
    output  bpu2btq     btq_out,

    input   fetch2bpu   f_in,
    output  bpu2fetch   f_out
);
    logic flush;
    assign flush = cbru_in.flush;

    logic i_uen;
    BPU_UPD_PKT i_udat;
    assign i_uen = btq_in.uen;
    assign i_udat= btq_in.udat;
    assign btq_out.urdy = !flush;

    logic   step;
    FB_POS  cur, cur_s1n;

    s1_to_ghr s1_2_ghr; 
    ghr_to_s1 ghr_2_s1;

    struct packed {
        logic       wen;
        FTQ_ENTRY   wdat;
    } pred_2_ftq_skid;

    struct packed {
        logic   rdy;
    } ftq_skid_2_pred;

    pred_s1 s1 (
        .clock,
        .reset,

        .i_uen,
        .i_udat,

        .i_pos  (cur),
        .ghr_out(s1_2_ghr),
        .ghr_in (ghr_2_s1),

        .o_pos  (cur_s1n),
        .o_rdy  (ftq_skid_2_pred.rdy),
        .o_wen  (pred_2_ftq_skid.wen),
        .o_dat  (pred_2_ftq_skid.wdat)
    );

    // struct packed {
    //     // fetch query
    //     WADDR       i_qry;

    //     logic       o_vld;
    //     FTB_ENTRY   o_tgt;

    //     // puq updates
    //     logic       i_uen;
    //     FTB_UPD_PKT i_udat;
    // } uftb_io;

    // struct packed {
    //     // fetch
    //     `CNT_TYPE(NUM_BR_SLOTS) wen_cnt;
    //     logic [NUM_BR_SLOTS-1:0]wpred, wshf_out;

    //     GHR_IDX base_n1;
    //     logic [GHR_LEN-1:0] rd_ghist;
    // } ghr_io;

    // struct packed {
    //     logic [NUM_BR_SLOTS-1:0] pred;
    //     logic [GHR_LEN-1:0] hash;
    // } gshare_io;

    // struct packed {
    //     logic       wen;
    //     FTQ_ENTRY   wdat;
    // } pred_2_ftq_skid;

    // struct packed {
    //     logic   rdy;
    // } ftq_skid_2_pred;

    // assign uftb_io.i_qry = cur.base;
    // assign uftb_io.i_uen = i_uen;
    // assign uftb_io.i_udat= '{
    //     base        : i_udat.base,
    //     fb_off      : i_udat.fb_off,
    //     take        : i_udat.take,
    //     tgt         : i_udat.tgt,

    //     md          : i_udat.md
    // };

    // uftb #(
    //     .NUM_LINES(16)
    // ) uftb0 (
    //     .clock,
    //     .reset,

    //     .i_qry  (uftb_io.i_qry),

    //     .o_vld  (uftb_io.o_vld),
    //     .o_tgt  (uftb_io.o_tgt),

    //     .i_uen  (uftb_io.i_uen),
    //     .i_udat (uftb_io.i_udat)
    // );

    // logic [NUM_BR_SLOTS-1:0] pred;
    // logic pred_any;
    // `IDX_TYPE(NUM_BR_SLOTS) pred_idx;
    // ffs #(
    //     .VECW(NUM_BR_SLOTS)
    // ) ff_take (
    //     .i_vec(pred),
    //     .o_vld(pred_any),
    //     .o_idx(pred_idx)
    // );

    // logic [NUM_BR_SLOTS-1:0] in_ghr;
    // always_comb begin
    //     FTB_ENTRY e;
    //     FTB_BR_SLOT slot;
    //     WADDR pc_flt, pc_jmp;
    //     logic leq0, leq1;
    //     `CNT_TYPE(NUM_BR_SLOTS) ghr_wvld_cnt;

    //     const FTB_MD1 COND_MD = '{
    //         cond : 1,
    //         call : 0,
    //         ret  : 0,
    //         jalr : 0
    //     };

    //     e = uftb_io.o_tgt;

    //     // ignore branches before the current FB-offset
    //     // cmp4(off, e.br_slot[0].off, eq0, lt0);
    //     // cmp4(off, e.br_slot[1].off, eq1, lt1);
    //     // leq0 = eq0 || lt0;
    //     // leq1 = eq1 || lt1;
    //     leq0 = cur.off <= e.br_slot[0].off;
    //     leq1 = cur.off <= e.br_slot[1].off;
    //     pred[0] =
    //         !e.br_slot[0].vld ? 0 :
    //         leq0 && gshare_io.pred[0];
    //         // leq0 && query_sc(e.br_slot[0].sc);
    //     pred[1] =
    //         !e.br_slot[1].vld ? 0 :
    //         leq1 && (!e.md1.cond || gshare_io.pred[1]);
    //         // leq1 && (!e.md1.cond || query_sc(e.br_slot[1].sc));
    //     if (!uftb_io.o_vld)
    //         pred = '0;

    //     in_ghr[0] =
    //         (!e.br_slot[0].vld || !leq0) ? 0 : 1;
    //     in_ghr[1] =
    //         (!e.br_slot[1].vld || !leq1) ? 0 :
    //         ~(pred_any & ~pred_idx);
    //     ghr_wvld_cnt = $countones(in_ghr);

    //     slot = e.br_slot[pred_idx];
    //     step = ftq_skid_2_pred.rdy;
    //     pred_2_ftq_skid.wen = step;


    //     if (!step || !uftb_io.o_vld)
    //         ghr_io.wen_cnt = 0;
    //     else
    //         ghr_io.wen_cnt = ghr_wvld_cnt;
    //     ghr_io.wpred = pred >> !leq0; // !leq0 is in_ghr[0] without the validity check
    //         /* FIXME: extremely hacky
    //         When the current fb off is BEYOND the 1st branch slot, then
    //         the first branch we can shift into the GHR is the 2nd branch slot. */

    //     pc_flt = cur.base + `UCAST_LEN(
    //         (e.end_off == 4'd15)
    //             ? 16
    //             : e.end_off + `UCAST_FIT(1),
    //         16
    //     );

    //     pc_jmp = slot.tgt;
    //     cur_n.base =
    //         !uftb_io.o_vld ? cur.base + `UCAST_FIT(16) :
    //         pred_any ? pc_jmp : pc_flt;

    //     pred_2_ftq_skid.wdat = '{
    //         base_n      : cur_n.base,
    //         // hash        : gshare_io.hash,

    //         ft          : !pred_any,
    //         pred_idx    : pred_idx,
    //         off         : 
    //             !uftb_io.o_vld ? 15 :
    //             pred_any ? slot.off : e.end_off,
    //         hit         : uftb_io.o_vld,
            
    //         slot        : '0, // filled below
    //         in_ghr      : in_ghr,
    //         ghr_base_n1 : ghr_io.base_n1,
    //         always_take : slot.always_take,
    //         md          : (pred_idx == 0) ? COND_MD : e.md1
    //     };

    //     for (int i = 0; i < NUM_BR_SLOTS; ++i) begin
    //         pred_2_ftq_skid.wdat.slot[i] = '{
    //             vld : e.br_slot[i].vld,
    //             off : e.br_slot[i].off
    //         };
    //     end
    // end

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
    // logic [FH_LEN-1:0] fh, rd_fh;
    // fhr #(
    //     .GHR_LEN    (GHR_LEN),
    //     .FH_LEN     (FH_LEN),

    //     .WPORTS     (NUM_BR_SLOTS)
    // ) fhr0 (
    //     .clock,
    //     .reset,

    //     .flush,

    //     .qry_ghist  (ghr_io.rd_ghist),
    //     .rd_fh,

    //     .wen_cnt    (ghr_io.wen_cnt),
    //     .wshf_in    (ghr_io.wpred),
    //     .wshf_out   (ghr_io.wshf_out),

    //     .fh
    // );

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

        .wen_cnt    (s1_2_ghr.wen_cnt),
        .wshf_in    (s1_2_ghr.wshf_in),
        // .wshf_out   (ghr_io.wshf_out),
        .base_n1    (ghr_2_s1.base_n1)

        // .ridx       (i_udat.ghr_base),
            /* FIXME: hacky fix. We want the history LEADING UP TO the branch––
            should not include the branch itself!! */
        // .rd_ghist   (ghr_io.rd_ghist)
    );

    // struct packed {
    //     logic   take;
    //     logic   slot_idx;

    //     logic   uen_gshare;
    //     logic   [FH_LEN-1:0] hash_gshare;
    // } upd_s2, upd_s2_n;
    // assign upd_s2_n = '{
    //     take        : i_udat.take,
    //     slot_idx    : i_udat.slot_idx,
    //     uen_gshare  : i_uen && i_udat.en_dir_update && i_udat.md.cond, // train only on conditional branches!
    //     hash_gshare : rd_fh ^ i_udat.base[FH_LEN-1:0]
    // };

    // always_ff @(posedge clock) begin
    //     if (!reset)
    //         assert (fhr0.fh == fhr0.compute_fh(ghr0.ghist)) else $fatal;
    // end

    // WADDR tmp;
    // assign tmp = i_udat.base - i_udat.fb_off;
    // gshare gshare0 (
    //     .clock,
    //     .reset,

    //     .i_uen      (upd_s2.uen_gshare),
    //     .i_utake    (upd_s2.take),
    //     .i_uslot_idx(upd_s2.slot_idx),
    //     .i_uhash    (upd_s2.hash_gshare),

    //     // .i_hash (fh),
    //     .i_hash (fh ^ cur.base[FH_LEN-1:0]),
    //     .o_pred (gshare_io.pred)

    // );

    struct packed {
        logic       wvld;
        logic       wen;
        FTQ_ENTRY   wdat;
    } ftq_skid_2_ftq;
    struct packed {
        logic       rdy;
    } ftq_2_ftq_skid;
    assign ftq_skid_2_ftq.wen = ftq_skid_2_ftq.wvld & ftq_2_ftq_skid.rdy;

    ppln_skid #(
        .FLUSH_MODE (SKID_FLUSH_RESET),
        .WIDTH      ($bits(FTQ_ENTRY))
    ) ftq_skid (
        .clock,
        .reset,
        .flush,
        .clmsk  ('0), // unused

        .i_vld (pred_2_ftq_skid.wen),
        .i_rdy (ftq_skid_2_pred.rdy),
        .i_msk ('0),
        .i_dat (pred_2_ftq_skid.wdat),

        .o_vld (ftq_skid_2_ftq.wvld),
        .o_rdy (ftq_2_ftq_skid.rdy),
        .o_msk (),
        .o_dat (ftq_skid_2_ftq.wdat)
    );

    ftq ftq0 (
        .clock,
        .reset,
        .flush,

        .rdy        (ftq_2_ftq_skid.rdy),
        .wen        (ftq_skid_2_ftq.wen),
        .wdat       (ftq_skid_2_ftq.wdat),

        .vld_scnt   (f_out.vld_scnt),
        .rdat       (f_out.dat),
        .ren_cnt    (f_in.ren_cnt)
    );

    always_ff @(posedge clock) begin
        if (reset)
            cur <= '0;
        else if (flush)
            cur <= '{
                base: cbru_in.flush_fb_base,
                off : cbru_in.flush_fb_off
            };
        // else if (step)
        //     cur <= cur_n;
        else if (pred_2_ftq_skid.wen)
            cur <= cur_s1n;

        // if (reset)
        //     upd_s2  <= '0;
        // else
        //     upd_s2  <= upd_s2_n;
    end

`ifdef DEBUG
    task print_bpu;
        $display(">> bpu");
        $display("(cur.base: %d, off: %0d, pred: [%b, %b]), step: %b, ftq_skid: %b, ftq: %b",
            cur.base,
            cur.off,
            pred[0],
            pred[1],
            step,
            ftq_skid_2_pred.rdy,
            ftq_2_ftq_skid.rdy
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