`include "sys_defs.svh"

parameter NUM_BR_SLOTS = 2;

/* Branch predictor unit (BPU):
generates PCs for decoupled fetch (experimental) */

/* TODO:
- scheme to squash speculatively generated fetch blocks?
See "5.3.1. L1 FTB Miss and L2 FTB Hit" in Reinman's paper "Optimizations Enabled..."
*/
module bpu (
    input   clock,
    input   reset,

    // TODO: wrap flush, clmsk, flush_take/base into a single "bru_res" bus.
    input   flush,
    input   WADDR   flush_PC,
    input   BMASK   clmsk,
    input   execute2complete_bru cbru_in,

    input   logic       i_uen,
    input   BPU_UPD_PKT i_udat,

    input   logic       i_ftq_rdy,
    output  logic       o_ftq_en,
    output  FTQ_ENTRY   o_ftq_dat
);
    logic step;
    WADDR pc_reg, pc_reg_n; // current fb/ftb base

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
        logic [$clog2(NUM_BR_SLOTS):0] f_en_cnt;
        logic [NUM_BR_SLOTS-1:0]       f_pred;
        logic [$clog2(NUM_BR_SLOTS):0] f_rdy_scnt;

        logic [NUM_BR_SLOTS-1:0][$clog2(GHR_BUF_SZ)-1:0] f_base;
        logic [NUM_BR_SLOTS-1:0][GHR_LEN-1:0] f_ghr;
    } ghr_io;

    assign uftb_io.i_qry = pc_reg;
    assign uftb_io.i_uen = i_uen;
    assign uftb_io.i_udat= '{
        base        : i_udat.base,
        pc_off      : i_udat.pc_off,
        take        : i_udat.take,
        tgt         : i_udat.tgt,

        always_take : i_udat.always_take,

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
    logic [$clog2(NUM_BR_SLOTS)-1:0] pred_any, pred_idx;
    ffs #(
        .VECW(NUM_BR_SLOTS)
    ) ff_take (
        .i_vec(pred),
        .o_vld(pred_any),
        .o_idx(pred_idx)
    );

    typedef logic [4:0] v5b;
    always_comb begin
        FTB_ENTRY e;
        FTB_BR_SLOT slot;
        WADDR pc_flt, pc_jmp;

        const FTB_MD1 COND_MD = '{
            cond : 1,
            call : 0,
            ret  : 0,
            jalr : 0
        };

        e = uftb_io.o_tgt;

        pred[0] =
            !e.br_slot[0].vld ? 0 :
            query_sc(e.br_slot[0].sc);
        pred[1] =
            !e.br_slot[1].vld ? 0 :
            e.md1.cond ? query_sc(e.br_slot[1].sc) :
            1;
        if (!uftb_io.o_vld)
            pred = '0;

        slot = e.br_slot[pred_idx];
        step = buf_io.i_rdy && (!pred_any || (pred_idx < ghr_io.f_rdy_scnt));

        ghr_io.f_en_cnt =
            !step ? 0 :
            pred_any ? pred_idx + 1 :
            NUM_BR_SLOTS;
        ghr_io.f_pred   = pred;

        pc_flt = WADDR'(pc_reg + v5b'(e.end_off + 1));
        pc_jmp = slot.tgt;
        pc_reg_n =
            !uftb_io.o_vld ? pc_reg + 16 :
            pred_any ? pc_jmp : pc_flt;

        buf_io.i_dat = '{
            base_n      : pc_reg_n,
            ft          : !pred_any,
            off         : pred_any ? slot.off : e.end_off,
            vld         : slot.vld,
            always_take : slot.always_take,
            md          : (pred_idx == 0) ? COND_MD : e.md1.cond
        };
    end

    ghr #(
        .DEPTH      (GHR_BUF_SZ),
        .NUM_FU_BRU (`NUM_FU_BRU),
        .GHR_LEN    (GHR_LEN),
        .N          (NUM_BR_SLOTS) // up to 2 branches per FTB_ENTRY
    ) ghr0 (
        .clock,
        .reset,

        .flush,
        .clmsk,
        .flush_take (cbru_in.dat[0].take),
        .flush_base (cbru_in.dat[0].ghr_base),

        .ex_en      (cbru_in.en[0]),
        .ex_idx     (cbru_in.dat[0].ghr_base),

        .f_en_cnt   (ghr_io.f_en_cnt),
        .f_pred     (ghr_io.f_pred),
        .f_rdy_scnt (ghr_io.f_rdy_scnt),
        .f_base     (ghr_io.f_base),
        .f_ghr      (ghr_io.f_ghr)
    );

    struct packed {
        logic i_rdy;
        FTQ_ENTRY i_dat;
    } buf_io;

    ppln_skid #(
        .FLUSH_MODE (SKID_FLUSH_RESET),
        .WIDTH      ($bits(FTQ_ENTRY))
    ) buf_ftq (
        .clock,
        .reset,
        .flush,
        .clmsk,

        .i_vld (step), // FIXME: should this be step without the buf_io.i_rdy component?
        .i_rdy (buf_io.i_rdy),
        .i_msk ('0),
        .i_dat (buf_io.i_dat),

        .o_vld (o_ftq_en),
        .o_rdy (i_ftq_rdy),
        .o_msk (),
        .o_dat (o_ftq_dat)
    );

    always_ff @(posedge clock) begin
        if (reset)
            pc_reg <= '0;
        else if (flush)
            pc_reg <= flush_PC;
        else
            pc_reg <= pc_reg_n;
    end

endmodule