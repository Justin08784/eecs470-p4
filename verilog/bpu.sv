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

    // TODO: wrap flush, clmsk, flush_take/base into a single "bru_res" bus.
    input   flush,
    input   WADDR   flush_fb_base,
    input   logic [3:0] flush_fb_off,
    input   BMASK   clmsk,
    input   execute2complete_bru cbru_in,

    input   logic       i_uen,
    input   BPU_UPD_PKT i_udat,

    input   logic       i_ftq_rdy,
    output  logic       o_ftq_en,
    output  FTQ_ENTRY   o_ftq_dat
);
    logic step;
    logic [3:0] off; // in-FB offset
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
        `CNT_TYPE(NUM_BR_SLOTS) f_en_cnt;
        logic [NUM_BR_SLOTS-1:0]f_pred;
        `CNT_TYPE(NUM_BR_SLOTS) f_rdy_scnt;

        GHR_IDX [NUM_BR_SLOTS-1:0]  f_base;
        logic [NUM_BR_SLOTS-1:0][GHR_LEN-1:0] f_ghr;
    } ghr_io;

    assign uftb_io.i_qry = pc_reg;
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

    always_comb begin
        FTB_ENTRY e;
        FTB_BR_SLOT slot;
        WADDR pc_flt, pc_jmp;
        logic leq0, leq1;

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
        leq0 = off <= e.br_slot[0].off;
        leq1 = off <= e.br_slot[1].off;
        pred[0] =
            !e.br_slot[0].vld ? 0 :
            leq0 && query_sc(e.br_slot[0].sc);
        pred[1] =
            !e.br_slot[1].vld ? 0 :
            leq1 && (!e.md1.cond || query_sc(e.br_slot[1].sc));
        if (!uftb_io.o_vld)
            pred = '0;

        slot = e.br_slot[pred_idx];
        step = buf_io.i_rdy && (!pred_any || (pred_idx < ghr_io.f_rdy_scnt));

        if (!step || !uftb_io.o_vld)
            ghr_io.f_en_cnt = 0;
        else
            ghr_io.f_en_cnt = pred_any
                ? pred_idx + `UCAST_FIT(1)
                : NUM_BR_SLOTS;
        ghr_io.f_pred = pred;

        pc_flt = pc_reg + `UCAST_LEN(
            (e.end_off == 4'd15)
                ? 16
                : e.end_off + `UCAST_FIT(1),
            16
        );

        pc_jmp = slot.tgt;
        pc_reg_n =
            !uftb_io.o_vld ? pc_reg + `UCAST_FIT(16) :
            pred_any ? pc_jmp : pc_flt;

        buf_io.i_dat = '{
            base_n      : pc_reg_n,

            ft          : !pred_any,
            pred_idx    : pred_idx,
            off         : 
                !uftb_io.o_vld ? 15 :
                pred_any ? slot.off : e.end_off,
            hit         : uftb_io.o_vld,
            
            slot        : '0, // filled below
            always_take : slot.always_take,
            md          : (pred_idx == 0) ? COND_MD : e.md1.cond
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
    assign ghr_io.f_rdy_scnt = NUM_BR_SLOTS;

    // ghr #(
    //     .DEPTH      (GHR_BUF_SZ),
    //     .NUM_FU_BRU (NUM_FU_BRU),
    //     .GHR_LEN    (GHR_LEN),
    //     .N          (NUM_BR_SLOTS) // up to 2 branches per FTB_ENTRY
    // ) ghr0 (
    //     .clock,
    //     .reset,

    //     .flush,
    //     .clmsk,
    //     .flush_take (cbru_in.dat[0].take),
    //     .flush_base (cbru_in.dat[0].ghr_base),

    //     .ex_en      (cbru_in.en[0]),
    //     .ex_idx     (cbru_in.dat[0].ghr_base),

    //     .f_en_cnt   (ghr_io.f_en_cnt),
    //     .f_pred     (ghr_io.f_pred),
    //     .f_rdy_scnt (ghr_io.f_rdy_scnt),
    //     .f_base     (ghr_io.f_base),
    //     .f_ghr      (ghr_io.f_ghr)
    // );

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
        .clmsk,

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
        if (reset) begin
            pc_reg <= '0;
            off    <= '0;
        end else if (flush) begin
            pc_reg <= flush_fb_base;
            off    <= flush_fb_off;
        end else if (step) begin
            pc_reg <= pc_reg_n;
            off    <= '0;
        end
    end

`ifdef DEBUG
    task print_bpu;
        $display(">> bpu");
        $display("(pc_reg: %d, off: %0d, pred: [%b, %b]), step: %b, buf_rdy: %b, ftq_rdy: %b",
            pc_reg,
            off,
            pred[0],
            pred[1],
            step,
            buf_io.i_rdy,
            i_ftq_rdy
        );

        $display("<< bpu");
    endtask
`endif

endmodule