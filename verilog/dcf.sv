`include "sys_defs.svh"

/* PC gen stage for decoupled fetch (experimental) */
module pc_gen (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,

    input   puq2fetch i_upd
);
    WADDR cti; // PC of current cti (control transfer insn)

    struct packed {
        // in
        logic ren;
        logic wen;
        WADDR wtgt;
        // out
        WADDR rtgt;
    } ras_io;
    ras ras0 (
        .clock,
        .reset,
        .flush  ('0),
        .clmsk  ('0),

        .if_snap_pre(),
        .if_snap_pos(),

        .rtgt   (ras_io.rtgt),
        .ren    ('0),
        .wen    ('0),
        .wtgt   ('0), // npc

        .snap_in('0),
        .empty  ()
    );

    struct packed {
        // in
        logic en;

        // out
        logic pred;
        logic rdy;
        logic [$clog2(GHR_BUF_SZ)-1:0] base;
        logic [GHR_LEN-1:0] ghr;
    } ghr_io;
    ghr #(
        .DEPTH      (GHR_BUF_SZ),
        .NUM_FU_BRU (`NUM_FU_BRU),
        .GHR_LEN    (GHR_LEN),
        .N          (1)
    ) ghr0 (
        .clock,
        .reset,
        .flush      ('0),
        .clmsk      ('0),
        .flush_take ('0),
            /* ^^ Do we really need this? Why not just let GHR
            invert whatever was there. */
        .flush_base ('0),

        .ex_en      ('0),
        .ex_idx     ('0),

        .f_en_cnt   ('0),
        .f_pred     (ghr_io.pred),
        .f_rdy_scnt (ghr_io.rdy),
        .f_base     (ghr_io.base),
        .f_ghr      (ghr_io.ghr)
    );

    struct packed {
        logic sel;
        logic pred_bim;
        logic pred_gshare;
        logic [GHR_LEN-1:0] hash;
    } dp_io; // dir pred
    chooser #(
        .GHR_LEN    (GHR_LEN),
        .N          (1)
    ) chooser0 (
        .clock,
        .reset,

        .i_upd,

        .i_qry  (cti),
        .o_sel  (dp_io.sel)
    );

    bim #(
        .GHR_LEN    (GHR_LEN),
        .N          (1)
    ) bim0 (
        .clock,
        .reset,

        .i_upd,

        .i_qry  (cti),
        .o_pred (dp_io.pred_bim)
    );

    gshare #(
        .GHR_LEN    (GHR_LEN),
        .N          (1)
    ) gshare0 (
        .clock,
        .reset,

        .i_upd,

        .i_ghr  (ghr_io.ghr),
        .i_qry  (cti),
        .o_hash (dp_io.hash),
        .o_pred (dp_io.pred_gshare)
    );


endmodule