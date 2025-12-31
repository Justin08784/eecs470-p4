`include "dcache_block_direct.svh"
`include "sys_defs.svh"

typedef struct packed {
    // logic       ret;    // retired?
    // DWADDR      dst;
    ADDR        dst;    // alternative: DWADDR + MEM_BLOCK
    MEM_SIZE    size;
    // logic[3:0]  write_byte_mask;
    DATA_BLOCK  dat;
} SQ_ENTRY;

// h<=t
// 0, 0
// 0, 1 // impossible
// 1, 0 // impossible
// 1, 1

// t> h
// 0, 0 // impossible
// 0, 1 
// 1, 0
// 1, 1 // impossible

// h <= x
// x <  t

/* Store queue */
module sq #(
    parameter SQ_SZ =SQ_SZ, // num elements
    parameter DSQ_SZ=2*SQ_SZ,
    parameter N     =N
) (
    output  logic           any_pending_wrmems,

    input   logic           clock,
    input   logic           reset,
    input   logic           flush,
    input   BMASK           clmsk,

    // wrmem
    output  sq2dcache       dcache_out,
    input   dcache2sq       dcache_in,

    // retire
    input   `CNT_TYPE(N)    r_in_en_cnt,

    // complete (write)
    input   execute2complete_str cstr_in,

    // dispatch
        // alloc snapshot
    input   comm2snap_bus   snap_in,
        // alloc entry
    output  sq2dispatch     d_out,
    input   dispatch2sq     d_in
);
    initial begin
        assert(`is_pow2(SQ_SZ)) else $fatal;
    end
    localparam DPORTS = N;          // dispatch  ports (in-order)
    localparam CPORTS = NUM_FU_STR; // complete ports (*OUT-OF-ORDER*)
    localparam RPORTS = N;          // retire ports (in-order) <merely a pointer bump>
    // localparam WRMEM_PORTS = 1;  // write mem ports (in-order) <when we actually write to memory>

    struct packed {
        logic[SQ_SZ-1:0]used;
        logic[SQ_SZ-1:0]pol;    // wrap polarity (msb of dsq index)
        logic[SQ_SZ-1:0]cpl;    // completed? (data + address)
    } hdr, hdr_n;
    SQ_ENTRY [SQ_SZ-1:0]state, state_n;
    `IDX_TYPE(DSQ_SZ)   head, tail, snap;
    `CNT_TYPE(SQ_SZ)    used, free, retired, retired_n; // retired := retired but not wrmem'd. used = retired + "completed but not retired" + "dispatched but not completed"
    logic wrmem_en;
    assign any_pending_wrmems = retired != 0 || r_in_en_cnt != 0;

    logic [1:0][`IDX_SIZE(DSQ_SZ)-1:0] wrmem_idxs_n;
    logic [DPORTS:0][`IDX_SIZE(DSQ_SZ)-1:0] d_idxs_n;
    assign d_out.dsq_idxs_n = d_idxs_n[DPORTS-1:0];

    ring_ctr #(
        .DEPTH      (SQ_SZ),
        .RPORTS     (1),
        .WPORTS     (DPORTS),
        .FLUSH_MODE (FIFO_FLUSH_SNAP_TAIL)
    ) ring_ctr0 (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .flush_snap (snap[`IDX_SIZE(SQ_SZ)-1:0]),

        .rd_en_cnt  (wrmem_en),
        .wr_en_cnt  (d_in.wen_cnt),

        .head       (),
        .tail       (),
        .rd_idxs_n  (),
        .wr_idxs_n  (),

        .used       (used),
        .free       (free),
        .used_scnt  (),
        .free_scnt  (d_out.rdy_scnt)
    );

    ring_ctr #(
        .DEPTH      (DSQ_SZ),
        .RPORTS     (1),
        .WPORTS     (DPORTS),
        .FLUSH_MODE (FIFO_FLUSH_SNAP_TAIL)
    ) ring_ctr1 (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .flush_snap (snap),

        .rd_en_cnt  (wrmem_en),
        .wr_en_cnt  (d_in.wen_cnt),

        .head       (head), // NOTE: debug only
        .tail       (tail), // NOTE: debug only
        .rd_idxs_n  (wrmem_idxs_n),
        .wr_idxs_n  (d_idxs_n),

        .used       (),
        .free       (),
        .used_scnt  (),
        .free_scnt  ()
    );

    general_snaps #(
        .WIDTH      (`IDX_SIZE(DSQ_SZ))
    ) dsq_tails (
        .clock      (clock),

        .rmsk       (clmsk),
        .rdat       (snap),

        .wen        (snap_in.snap_en),
        .wmsk       (snap_in.b1hot_n),
        .wdat       (snap_in.dsq_tail)
    );

    // wrmem
    SQ_ENTRY wrmem_cand;
    assign wrmem_cand = state[wrmem_idxs_n[0][`IDX_SIZE(SQ_SZ)-1:0]];
    assign dcache_out = '{
        vld : retired != 0,
        addr: wrmem_cand.dst,
        size: wrmem_cand.size,
        dat : wrmem_cand.dat
    };
    assign wrmem_en = dcache_in.status == ST_SUCC; // TODO: with a nonblocking cache, this condition may no longer hold (and a dependent load may miss the value)

    // retire
    assign retired_n = (retired - wrmem_en) + r_in_en_cnt;

    logic opp_pol; // head -> tail span wraps?
    logic [SQ_SZ-1:0] geh, ltt, anded, orred, snap_used;
    assign opp_pol = head[`IDX_SIZE(DSQ_SZ)-1] ^ snap[`IDX_SIZE(DSQ_SZ)-1];
    for (genvar i = 0; i < SQ_SZ; ++i) begin
        assign geh[i] = i >= head[`IDX_SIZE(SQ_SZ)-1:0];
        assign ltt[i] = i <  snap[`IDX_SIZE(SQ_SZ)-1:0];
    end
    assign anded = geh & ltt; // [h, t)
    assign orred = geh | ltt; // [0, t) U [h, DEPTH)
    assign snap_used = opp_pol ? orred : anded;

    always_comb begin
        hdr_n   = hdr;
        state_n = state;

        // complete (flush)
        if (flush)
            hdr_n.used = snap_used;

        // retired
        if (wrmem_en) begin
            int unsigned sq_idx;
            sq_idx = wrmem_idxs_n[0][`IDX_SIZE(SQ_SZ)-1:0];

            hdr_n.used[sq_idx]  = 1'b0;
        end

        // complete (cstr)
        for (int i = 0; i < CPORTS; ++i) begin
            if (cstr_in.en[i]) begin
                int unsigned sq_idx;
                sq_idx = cstr_in.dat[i].dsq_idx[`IDX_SIZE(SQ_SZ)-1:0];

                hdr_n.cpl[sq_idx]   = 1'b1;

                state_n[sq_idx].dst = cstr_in.dat[i].dst;
                state_n[sq_idx].size= cstr_in.dat[i].size;
                state_n[sq_idx].dat = cstr_in.dat[i].dat;
            end
        end

        // dispatch
        for (int i = 0; i < DPORTS; ++i) begin
            if (i < d_in.wen_cnt & ~flush) begin
                int unsigned sq_idx;
                sq_idx = d_idxs_n[i][`IDX_SIZE(SQ_SZ)-1:0];

                hdr_n.used[sq_idx]  = 1'b1;
            end
        end
        for (int i = 0; i < DPORTS; ++i) begin
            if (i < d_in.wen_cnt) begin
                int unsigned sq_idx;
                sq_idx = d_idxs_n[i][`IDX_SIZE(SQ_SZ)-1:0];

                hdr_n.pol[sq_idx]   = d_idxs_n[i][`IDX_SIZE(DSQ_SZ)-1];
                hdr_n.cpl[sq_idx]   = 1'b0;
            end
        end
    end

    always_ff @(posedge clock) begin
`ifndef SYNTH
        if (~reset) begin
            if (d_in.wen_cnt > free)
                $error("SQ overflow!");
            if (r_in_en_cnt > used)
                $error("SQ underflow!");
        end
`endif

        hdr     <= hdr_n;
        state   <= state_n;
        retired <= retired_n;

        if (reset) begin
            hdr.used<= '0;
            retired <= '0;
        end
    end

`ifdef DEBUG
    task print_sq;
        logic [SQ_SZ-1:0] sq_vld;

        $display("  | >> SQ >>");
        for (int i = 0; i < N; ++i) begin
            $display("snap_in[%1d]: en: %b, b1hot_n: %b, rob_tail: %2d",
                i,
                snap_in.snap_en[i],
                snap_in.b1hot_n[i],
                snap_in.rob_tail[i]
            );
        end

        $display("d_out.rdy_scnt: %2d", d_out.rdy_scnt);
        $display("d_in.wen_cnt: %1d, retired: %2d", d_in.wen_cnt, retired);

        $display("head: %d, tail: %d, used: %d, free: %d", wrmem_idxs_n[0], d_idxs_n[0], used, free);
        $display("flush: %b, flush_snap: %2d, clmsk: %b", flush, snap, clmsk);
        $display("rd_en_cnt: %2d, wr_en_cnt: %2d", wrmem_en, d_in.wen_cnt);
        $display("cstr_in: en: %b, sq_idx: %d, size: %d, dst: %x, dat: %x",
            cstr_in.en[0],
            cstr_in.dat[0].dsq_idx,
            cstr_in.dat[0].size,
            cstr_in.dat[0].dst,
            cstr_in.dat[0].dat
        );
        sq_vld = '0;
        for (int cnt = 0; cnt < used; ++cnt)
            sq_vld[(head + cnt) % SQ_SZ] = 1;

        for (int i = 0; i < SQ_SZ; ++i) begin
            if (!sq_vld[i]) begin
                $display("SQ[%2d]: {used: %b",
                    i,
                    hdr.used[i]
                );
                continue;
            end

            $display("SQ[%2d]: {used: %b, pol: %b, cpl: %b}, dst: %x, size: %1d, dat: %x",
                i,
                hdr.used[i],
                hdr.pol[i],
                hdr.cpl[i],
                state[i].dst,
                state[i].size,
                state[i].dat
            );
        end

        $display("  | << SQ <<");
    endtask

`endif


endmodule
