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

typedef struct packed {
    logic [1:0] in_win;
    logic [1:0] in_ghr;

    logic [1:0] pred_uftb; // bimodal sc bits
    logic       hit_uftb;
    GHR_IDX     ghr_base_n1;

    WADDR       pc_ft;

    FTB_ENTRY   fb;
} S1_S2_PKT;

module pred_s1 (
    input   clock,
    input   reset,
    input   flush,
    input   s2_steer,

    input   logic       i_uen,
    input   BPU_UPD_PKT i_udat,

    input   FB_POS      i_pos,
    output  FB_POS      o_pos_n,

    input   ghr_to_s1   i_ghr,
    output  s1_to_ghr   o_ghr,

    output  logic       s1_step,
    input   logic       i_s2_rdy,
    output  logic       o_s2_vld,
    output  S1_S2_PKT   o_s2_dat
);
    assign s1_step = ~o_s2_vld | i_s2_rdy; // FIXME

    logic       hit;
    FTB_ENTRY   row;
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

    assign o_ghr = '{
        wen_cnt : (s1_step & hit) ? $countones(in_ghr) : 0,
        wshf_in : pred >> ~in_win[0]
    };


    FTB_BR_SLOT slot;
    assign slot = row.br_slot[pred_idx];
    WADDR pc_ft, pc_jmp;
    assign pc_ft = i_pos.base + `UCAST_LEN(
        (row.end_off == 4'd15)
            ? 16
            : row.end_off + `UCAST_FIT(1),
        16
    );
    assign pc_jmp = slot.tgt;
    assign o_pos_n = '{
        base :
            !hit    ? i_pos.base + `UCAST_FIT(16) :
            pred_any? pc_jmp : pc_ft,

        off : '0
    };


    S1_S2_PKT o_s2_dat_n;
    assign o_s2_dat_n = '{
        in_win      : in_win,
        in_ghr      : in_ghr,
        pred_uftb   : pred,
        hit_uftb    : hit,
        ghr_base_n1 : i_ghr.base_n1,
        pc_ft       : pc_ft,

        fb          : row 
    };

    always_ff @(posedge clock) begin
        if (reset | flush | s2_steer) begin
            o_s2_vld <= 0;
            o_s2_dat <= '0;
        end else if (s1_step) begin
            o_s2_vld <= 1;
            o_s2_dat <= o_s2_dat_n;
        end
    end

endmodule;


typedef struct packed {
    logic [NUM_BR_SLOTS-1:0] s2_steer_wen;
    logic [NUM_BR_SLOTS-1:0] s2_steer_take;
    GHR_IDX s2_steer_idx;
} s2_to_ghr;

typedef struct packed {
    logic[FH_LEN-1:0] fh, rd_fh;
} fhr_to_s2;


module pred_s2 (
    input   clock,
    input   reset,
    input   flush,
    output  logic       s2_steer,

    input   logic       i_uen,
    input   BPU_UPD_PKT i_udat,

    input   FB_POS      i_pos,
    output  FB_POS      o_pos_n,

    input   fhr_to_s2   i_fhr,
    output  s2_to_ghr   o_ghr,

    output  logic       o_s1_rdy,
    input   logic       i_s1_vld,
    input   S1_S2_PKT   i_s1_dat,

    input   logic       i_s3_rdy,
    output  logic       o_s3_vld,
    output  FTQ_ENTRY   o_s3_dat
);
    struct packed {
        logic   take;
        logic   slot_idx;

        logic   uen_gshare;
        logic   [FH_LEN-1:0] hash_gshare;
    } upd_s2, upd_s2_n;
    assign upd_s2_n = '{
        take        : i_udat.take,
        slot_idx    : i_udat.slot_idx,
        uen_gshare  : i_uen && i_udat.en_dir_update && i_udat.md.cond, // train only on conditional branches!
        hash_gshare : i_fhr.rd_fh ^ i_udat.base[FH_LEN-1:0]
    };

    logic [1:0] raw_pred, raw_pred_n;

    logic [1:0] in_win;
    logic       hit;
    FTB_ENTRY   row;
    assign in_win = i_s1_dat.in_win;
    assign hit = i_s1_dat.hit_uftb;
    assign row = i_s1_dat.fb;

    gshare gshare0 (
        .clock,
        .reset,

        .i_uen      (upd_s2.uen_gshare),
        .i_utake    (upd_s2.take),
        .i_uslot_idx(upd_s2.slot_idx),
        .i_uhash    (upd_s2.hash_gshare),

        .i_hash     (i_fhr.fh ^ i_pos.base[FH_LEN-1:0]),
        .o_pred     (raw_pred_n)

    );

    logic [1:0] pred;
    logic pred_any, pred_idx;
    assign pred[0] = (hit & row.br_slot[0].vld & in_win[0])
        &  raw_pred[0];
    assign pred[1] = (hit & row.br_slot[1].vld & in_win[1])
        & (raw_pred[1] | ~row.md1.cond);
    assign pred_any = |pred;
    assign pred_idx = ~pred[0] & pred[1];

    logic [1:0] in_ghr;
    assign in_ghr[0] = row.br_slot[0].vld & in_win[0];
    assign in_ghr[1] = row.br_slot[1].vld & in_win[1] & ~(pred_any & ~pred_idx);

    assign s2_steer = (i_s1_vld & o_s1_rdy) & (pred != i_s1_dat.pred_uftb);
    assign o_ghr.s2_steer_wen[0]= |in_ghr;
    assign o_ghr.s2_steer_wen[1]= &in_ghr;
    assign o_ghr.s2_steer_take  = pred >> ~in_win[0];
    assign o_ghr.s2_steer_idx   = i_s1_dat.ghr_base_n1;


    FTB_BR_SLOT slot;
    assign slot = row.br_slot[pred_idx];
    WADDR pc_ft, pc_jmp;
    assign pc_ft = i_s1_dat.pc_ft;
    assign pc_jmp = slot.tgt;
    assign o_pos_n = '{
        base :
            !hit    ? i_pos.base + `UCAST_FIT(16) :
            pred_any? pc_jmp : pc_ft,

        off : '0
    };

    FTQ_ENTRY skid_wdat;
    localparam FTB_MD1 COND_MD = '{
        cond : 1,
        call : 0,
        ret  : 0,
        jalr : 0
    };
    always_comb begin
        skid_wdat = '{
            base_n      : o_pos_n.base,

            ft          : ~pred_any,
            pred_idx    : pred_idx,
            off         : 
                ~hit    ? 15 :
                pred_any? slot.off : row.end_off,
            hit         : hit,
            
            slot        : '0, // filled below
            in_ghr      : in_ghr,
            ghr_base_n1 : i_s1_dat.ghr_base_n1,
            always_take : slot.always_take,
            md          : (pred_idx == 0) ? COND_MD : row.md1
        };

        for (int i = 0; i < NUM_BR_SLOTS; ++i) begin
            skid_wdat.slot[i] = '{
                vld : row.br_slot[i].vld,
                off : row.br_slot[i].off
            };
        end
    end

    ppln_skid #(
        .FLUSH_MODE (SKID_FLUSH_RESET),
        .WIDTH      ($bits(FTQ_ENTRY))
    ) ftq_skid (
        .clock,
        .reset,
        .flush,
        .clmsk  ('0), // unused

        .i_vld (i_s1_vld),
        .i_rdy (o_s1_rdy),
        .i_msk ('0),
        .i_dat (skid_wdat),

        .o_vld (o_s3_vld),
        .o_rdy (i_s3_rdy),
        .o_msk (),
        .o_dat (o_s3_dat)
    );


    always_ff @(posedge clock) begin
        if (reset) begin
            raw_pred<= '0;
            upd_s2  <= '0;
        end else begin
            raw_pred<= raw_pred_n;
            upd_s2  <= upd_s2_n;
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
    // convenience signals
    logic flush;
    assign flush = cbru_in.flush;

    logic i_uen;
    BPU_UPD_PKT i_udat;
    assign i_uen = btq_in.uen;
    assign i_udat= btq_in.udat;
    assign btq_out.urdy = !flush;

    // controls
    logic s1_step;
    logic s2_steer;

    // state and succs
    FB_POS  pos, pos_s1_n, pos_s2_n;



    // i/o's
    s1_to_ghr s1_2_ghr; 
    ghr_to_s1 ghr_2_s1;

    struct packed {
        logic       vld;
        S1_S2_PKT   dat;
    } s1_2_s2;

    struct packed {
        logic rdy;
    } s2_2_s1;

    pred_s1 s1 (
        .clock,
        .reset,
        .flush,
        .s1_step,
        .s2_steer,

        .i_uen,
        .i_udat,

        .i_pos      (pos),
        .o_pos_n    (pos_s1_n),

        .i_ghr      (ghr_2_s1),
        .o_ghr      (s1_2_ghr),

        .i_s2_rdy   (s2_2_s1.rdy),
        .o_s2_vld   (s1_2_s2.vld),
        .o_s2_dat   (s1_2_s2.dat)
    );


    // i/o's
    s2_to_ghr s2_2_ghr; 
    fhr_to_s2 fhr_2_s2;

    struct packed {
        logic vld;
        logic wen;
        FTQ_ENTRY dat;
    } pred_2_ftq;
    struct packed {
        logic rdy;
    } ftq_2_pred;
    assign pred_2_ftq.wen = pred_2_ftq.vld & ftq_2_pred.rdy;

    pred_s2 s2 (
        .clock,
        .reset,
        .flush,
        .s2_steer,

        .i_uen,
        .i_udat,

        .i_pos      (pos),
        .o_pos_n    (pos_s2_n),

        .i_fhr      (fhr_2_s2),
        .o_ghr      (s2_2_ghr),

        .o_s1_rdy   (s2_2_s1.rdy),
        .i_s1_vld   (s1_2_s2.vld),
        .i_s1_dat   (s1_2_s2.dat),

        .i_s3_rdy   (ftq_2_pred.rdy),
        .o_s3_vld   (pred_2_ftq.vld),
        .o_s3_dat   (pred_2_ftq.dat)
    );

    struct packed {
        logic [GHR_LEN-1:0] rd_ghist;
        logic [1:0] wshf_out;
    } ghr2fhr;

    fhr #(
        .GHR_LEN    (GHR_LEN),
        .FH_LEN     (FH_LEN),

        .WPORTS     (NUM_BR_SLOTS)
    ) fhr0 (
        .clock,
        .reset,

        .redir      (flush | s2_steer),

        .qry_ghist  (ghr2fhr.rd_ghist),
        .rd_fh      (fhr_2_s2.rd_fh),

        .wen_cnt    (s1_2_ghr.wen_cnt),
        .wshf_in    (s1_2_ghr.wshf_in),
        .wshf_out   (ghr2fhr.wshf_out),

        .fh         (fhr_2_s2.fh)
    );

    logic [NUM_BR_SLOTS-1:0] flush_wen;
    logic [NUM_BR_SLOTS-1:0] flush_take;
    assign flush_wen[0] = flush;
    assign flush_wen[1] = 0;
    assign flush_take[0] = cbru_in.take;
    assign flush_take[1] = 0;
    ghr #(
        .DEPTH      (GHR_BUF_SZ),
        .GHR_LEN    (GHR_LEN),

        .WPORTS     (NUM_BR_SLOTS)
    ) ghr0 (
        .clock,
        .reset,

        .redir      (flush | s2_steer),
        .redir_wen  (flush ? flush_wen  : s2_2_ghr.s2_steer_wen),
        .redir_take (flush ? flush_take : s2_2_ghr.s2_steer_take),
        .redir_idx  (flush ? cbru_in.flush_ghr_base : s2_2_ghr.s2_steer_idx),

        .wen_cnt    (s1_2_ghr.wen_cnt),
        .wshf_in    (s1_2_ghr.wshf_in),
        .wshf_out   (ghr2fhr.wshf_out),
        .base_n1    (ghr_2_s1.base_n1),

        .ridx       (i_udat.ghr_base),
        .rd_ghist   (ghr2fhr.rd_ghist)
    );

    ftq ftq0 (
        .clock,
        .reset,
        .flush,

        .rdy        (ftq_2_pred.rdy),
        .wen        (pred_2_ftq.wen),
        .wdat       (pred_2_ftq.dat),

        .vld_scnt   (f_out.vld_scnt),
        .rdat       (f_out.dat),
        .ren_cnt    (f_in.ren_cnt)
    );

    always_ff @(posedge clock) begin
        if (reset)
            pos <= '0;
        else begin
            if (flush)
                pos <= '{
                    base: cbru_in.flush_fb_base,
                    off : cbru_in.flush_fb_off
                };
            else if (s2_steer)
                pos <= pos_s2_n;
            else if (s1_step)
                pos <= pos_s1_n;
        end
    end

    // always_ff @(posedge clock) begin
    //     if (!reset)
    //         assert (fhr0.fh == fhr0.compute_fh(ghr0.ghist)) else $fatal;
    // end


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