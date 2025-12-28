`include "sys_defs.svh"

typedef struct packed {
    logic       cpl;    // completed? (data + address)
    // logic       ret;    // retired?
    // DWADDR      dst;
    ADDR        dst;    // alternative: DWADDR + MEM_BLOCK
    MEM_SIZE    size;
    // logic[3:0]  write_byte_mask;
    DATA_BLOCK  dat;
} SQ_ENTRY;

/* Store queue */
module sq #(
    parameter SQ_SZ =SQ_SZ, // num elements
    parameter N     =N
) (
    output  logic           used_any, // used by testbench to determine when to stop

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

    SQ_ENTRY [SQ_SZ-1:0]state, state_n;
    `IDX_TYPE(SQ_SZ)    head, tail, snap;
    `CNT_TYPE(SQ_SZ)    used, free, retired, retired_n; // retired := retired but not wrmem'd. used = retired + "completed but not retired" + "dispatched but not completed"
    logic wrmem_en;

    logic [1:0][`IDX_SIZE(SQ_SZ)-1:0] wrmem_idxs_n;
    logic [DPORTS:0][`IDX_SIZE(SQ_SZ)-1:0] d_idxs_n;
    assign d_out.sq_idxs_n = d_idxs_n[DPORTS-1:0];

    ring_ctr #(
        .DEPTH      (SQ_SZ),
        .RPORTS     (1),
        .WPORTS     (DPORTS),
        .FLUSH_MODE (FIFO_FLUSH_SNAP_TAIL)
    ) ring_ctr0 (
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

        .used       (used),
        .free       (free),
        .used_scnt  (used_any),
        .free_scnt  (d_out.rdy_scnt)
    );

    general_snaps #(
        .WIDTH      (`IDX_SIZE(SQ_SZ))
    ) sq_tails (
        .clock      (clock),

        .rmsk       (clmsk),
        .rdat       (snap),

        .wen        (snap_in.snap_en),
        .wmsk       (snap_in.b1hot_n),
        .wdat       (snap_in.sq_tail)
    );

    // wrmem
    SQ_ENTRY wrmem_cand;
    assign wrmem_cand = state[wrmem_idxs_n[0]];
    assign dcache_out = '{
        vld : retired != 0,
        addr: wrmem_cand.dst,
        size: wrmem_cand.size,
        dat : wrmem_cand.dat
    };
    assign wrmem_en = dcache_in.status == ST_SUCC; // FIXME: "only in mshr" counts as success. But there is no mshr forwarding, so a load to that address may miss it.

    // retire
    assign retired_n = (retired - wrmem_en) + (flush ? 1'b0 : r_in_en_cnt);

    // complete, dispatch
    always_comb begin
        state_n = state;
        for (int i = 0; i < CPORTS; ++i) begin
            if (cstr_in.en[i]) begin
                int unsigned sq_idx;
                sq_idx = cstr_in.dat[i].sq_idx;

                state_n[sq_idx].cpl = 1'b1;
                state_n[sq_idx].dst = cstr_in.dat[i].dst;
                state_n[sq_idx].size= cstr_in.dat[i].size;
                state_n[sq_idx].dat = cstr_in.dat[i].dat;
            end
        end

        for (int i = 0; i < DPORTS; ++i) begin
            if (i < d_in.wen_cnt)
                state_n[d_idxs_n[i]].cpl    = 1'b0;
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

        state   <= state_n;
        retired <= retired_n;

        if (reset)
            retired <= '0;
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

        $display("d_in.wen_cnt: %1d, retired: %2d", d_in.wen_cnt, retired);

        $display("head: %d, tail: %d, used: %d, free: %d", wrmem_idxs_n[0], d_idxs_n[0], used, free);
        $display("flush: %b, flush_snap: %2d, clmsk: %b", flush, snap, clmsk);
        $display("rd_en_cnt: %2d, wr_en_cnt: %2d", wrmem_en, d_in.wen_cnt);
        $display("cstr_in: en: %b, sq_idx: %d, size: %d, dst: %x, dat: %x",
            cstr_in.en[0],
            cstr_in.dat[0].sq_idx,
            cstr_in.dat[0].size,
            cstr_in.dat[0].dst,
            cstr_in.dat[0].dat
        );
        sq_vld = '0;
        for (int cnt = 0; cnt < used; ++cnt)
            sq_vld[(head + cnt) % SQ_SZ] = 1;

        for (int i = 0; i < SQ_SZ; ++i) begin
            if (!sq_vld[i]) begin
                $display("SQ[%2d]:", i);
                continue;
            end

            $display("SQ[%2d]: cpl: %b, dst: %x, size: %1d, dat: %x",
                i,
                state[i].cpl,
                state[i].dst,
                state[i].size,
                state[i].dat
            );
        end

        $display("  | << SQ <<");
    endtask

`endif


endmodule
