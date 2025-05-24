`include "sys_defs.svh"
module bp #(
    // parameter QUERY_SZ // i.e. number of branch slots, BTB read slots
    // parameter UPD_SZ    = BP_UPD_SZ
) (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK   clmsk,
    input   rename2snap_bus snap_in,

    // fetch npc query
    input   fetch2bp    f_in,
    output  bp2fetch    f_out,

    // execute
    input   execute2complete_bru cbru_in,

    // puq updates
    input   puq2fetch i_upd
);
    logic [`N-1:0] brch, cond, call, ret;
    assign brch = f_in.brch;
    assign cond = f_in.cond;
    assign call = f_in.call;
    assign ret  = f_in.ret;

    WADDR [`N:0] PC_n;
    assign PC_n = f_in.PC_n;

    logic [`N-1:0] f_en;
    assign f_en = f_in.f_en;

    logic [`N-1:0] btb_hit;
    WADDR [`N-1:0] btb_tgt;
    btb #(
        .QUERY_SZ(`N)
    ) btb0 (
        .clock,
        .reset,

        .i_qry(PC_n[`N-1:0]),
        .o_vld(btb_hit),
        .o_tgt(btb_tgt),

        .i_upd
    );

    // stop fetching beyond the first predicted taken branch
    logic [`N-1:0] raw_take;
    logic take_any;
    logic [$clog2(`N)-1:0] take_idx;
    logic empty; // ras empty?

    assign raw_take =
    call
    | ret
    | (btb_hit & ((brch & ~cond) | (cond & '1))); // FIXME: '1 = stand-in for direction predictor

    ffs #(
        .VECW(`N)
    ) ff_take (
        .i_vec(raw_take),
        .o_vld(take_any),
        .o_idx(take_idx)
    );

    logic ren, wen;
    WADDR ras_tgt;

    assign ren = take_any && f_en[take_idx] && ret [take_idx];
    assign wen = take_any && f_en[take_idx] && call[take_idx];
        /* Calls unconditionally write their NPC to the RAS, EVEN IF they 
        they miss in the BTB (we mark the call/ret as taken too, unintuitively).
        This ensures the subsequent return insn ––after the call inevitably
        triggers a flush–– is a hit on the RAS. */
    RAS_SNAP ras_snap_pre, ras_snap_pos;
    ras ras0 (
        .clock,
        .reset,
        .flush,
        .clmsk,

        .if_snap_pre(ras_snap_pre), // RAS top/used at start of cycle
        .if_snap_pos(ras_snap_pos), // " after the first taken branch (which may or may not be a ret/call)
        .rtgt   (ras_tgt),
        .ren,
        .wen,
        .wtgt   (PC_n[take_idx+1]), // npc

        .snap_in,
        .empty
    );

    ghr #(
        .DEPTH      (GHR_BUF_SZ),
        .NUM_FU_BRU (`NUM_FU_BRU),
        .GHR_LEN    (GHR_LEN),
        .N          (`N)
    ) ghr0 (
        .clock,
        .reset,
        .flush      ('0), // FIXME
        .clmsk,
        .flush_take (cbru_in.dat[0].take),
            /* ^^ Do we really need this? Why not just let GHR
            invert whatever was there. */
        .flush_base (cbru_in.dat[0].ghr_base),

        // .ex_en      (cbru_in.en),
        .ex_en      ('0), // FIXME
        .ex_idx     (cbru_in.dat[0].ghr_base),

        .f_en_cnt   (),
        .f_pred     ('0), // FIXME
        .f_rdy_scnt (),
        .f_base     (),
        .f_ghr      ()
    );

    assign f_out.take   = raw_take;
    assign f_out.lim_cnt= take_any ? take_idx + 1 : `N;

    generate
    for (genvar i = 0; i < `N; ++i) begin
        assign f_out.tgt[i] =
            ret[i] && !empty    ? ras_tgt :
            btb_hit[i]          ? btb_tgt[i]: PC_n[i+1];
            /* On btb_miss, use NPC as a fallback. (Note: "ret" and "call"
            will predict taken even BTB miss, so they their fake "prediction"
            target is the sequentially next PC).
            */
        assign f_out.ras_snap[i] = (ret[i] || call[i]) ? ras_snap_pos : ras_snap_pre;
            /*
            Observation:
            1. only rets/calls update the RAS.
            2. fetch accepts at most 1 taken branch per cycle.

            Trivially, the only situation which requires the post-ret/call snapshot of the RAS
            is when a the ret/call is the FIRST taken branch in the fetch group. In this
            situation, no insn except for the terminating ret/call needs the post update snapshot.
            */
    end
    endgenerate
endmodule