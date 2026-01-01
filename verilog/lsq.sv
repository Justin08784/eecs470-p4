`include "dcache_block_direct.svh"
`include "sys_defs.svh"

typedef struct packed {
    // logic       ret;    // retired?
    // DWADDR      dst;
    ADDR        dst;    // alternative: DWADDR + MEM_BLOCK
    MEM_SIZE    size;
    logic[3:0]  byte_mask;
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

    // issue (load only: sq RAW hazard query)
    input   rs2sq           rs_in,
    output  sq2rs           rs_out,

    // execute (load query & response)
    input   ld2sq           ld_in,
    output  sq2ld           ld_out,

    // dispatch
        // alloc snapshot
    input   comm2snap_bus   snap_in,
        // alloc entry
    output  sq2dispatch     d_out,
    input   dispatch2sq     d_in
);
    function automatic logic [SQ_SZ-1:0] compute_range_mask(
        input `IDX_TYPE(DSQ_SZ) head,
        input `IDX_TYPE(DSQ_SZ) tail
    );
        logic opp_pol; // head -> tail span wraps?
        logic [SQ_SZ-1:0] geh, ltt, anded, orred, used;
        opp_pol = head[`IDX_SIZE(DSQ_SZ)-1] ^ tail[`IDX_SIZE(DSQ_SZ)-1];
        for (int i = 0; i < SQ_SZ; ++i) begin
            geh[i] = i >= head[`IDX_SIZE(SQ_SZ)-1:0];
            ltt[i] = i <  tail[`IDX_SIZE(SQ_SZ)-1:0];
        end
        anded= geh & ltt; // [h, t)
        orred= geh | ltt; // [0, t) U [h, DEPTH)
        used = opp_pol ? orred : anded;
        return used;
    endfunction

    initial begin
        assert(`is_pow2(SQ_SZ)) else $fatal;
    end
    localparam DPORTS = N;          // dispatch  ports (in-order)
    localparam CPORTS = NUM_FU_STR; // complete ports (*OUT-OF-ORDER*)
    localparam RPORTS = N;          // retire ports (in-order) <merely a pointer bump>
    // localparam WRMEM_PORTS = 1;  // write mem ports (in-order) <when we actually write to memory>

    struct packed {
        logic[SQ_SZ-1:0]used;
        // logic[SQ_SZ-1:0]pol;    // wrap polarity (msb of dsq index)
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
        has_byte_mask: wrmem_cand.byte_mask,
        dat : wrmem_cand.dat
    };
    assign wrmem_en = dcache_in.status == ST_SUCC; // TODO: with a nonblocking cache, this condition may no longer hold (and a dependent load may miss the value)

    // retire
    assign retired_n = (retired - wrmem_en) + r_in_en_cnt;

    logic [SQ_SZ-1:0]snap_used;
    assign snap_used = compute_range_mask(head, snap);

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
                state_n[sq_idx].byte_mask = compute_byte_mask(cstr_in.dat[i].dst, cstr_in.dat[i].size);
                state_n[sq_idx].dat = cstr_in.dat[i].dat << {cstr_in.dat[i].dst[1:0], 3'b000};
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

                // hdr_n.pol[sq_idx]   = d_idxs_n[i][`IDX_SIZE(DSQ_SZ)-1];
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


    // load query & response
    WADDR query_word;
    SQ_IDX ld_in_sq_idx;
    logic[SQ_SZ-1:0] ncpl;
    logic[SQ_SZ-1:0] vld_older;
    logic[SQ_SZ-1:0] match_word;
    logic[3:0][SQ_SZ-1:0] byte_mask_table_T;
    logic[3:0][SQ_SZ-1:0] ok_table_T, ok_table_rotr_T, ok_youngest_sel_rotr_T, ok_youngest_sel_T;
    // logic[SQ_SZ-1:0][3:0] ok_table_rotr, ok_youngest_sel_rotr, ok_youngest_sel;
    // logic[SQ_SZ-1:0][3:0] ok_youngest_sel;

    assign query_word   = addr2w(ld_in.addr);
    assign ld_in_sq_idx = ld_in.dsq_idx[`IDX_SIZE(SQ_SZ)-1:0];

    assign vld_older    = compute_range_mask(head, ld_in.dsq_idx);
    for (genvar i = 0; i < SQ_SZ; ++i) begin
        assign ncpl[i]      = ~hdr.cpl[i];
        assign match_word[i]= query_word == addr2w(state[i].dst);
    end

    for (genvar j = 0; j < 4; ++j) begin
        for (genvar i = 0; i < SQ_SZ; ++i) begin
            assign byte_mask_table_T[j][i] = state[i].byte_mask[j];
            // assign ok_table_rotr[i][j] = ok_table_rotr_T[j][i];
        end
        assign ok_table_T[j]        = vld_older & match_word & byte_mask_table_T[j];
        assign ok_table_rotr_T[j]   = {ok_table_T[j], ok_table_T[j]} >> ld_in_sq_idx;

        assign ld_out.has_byte_mask[j] = |ok_table_T[j];
    end
    assign ld_out.any_older_ncpl_store = |(vld_older & ncpl);

    for (genvar j = 0; j < 4; ++j) begin
        always_comb begin
            ok_youngest_sel_rotr_T[j] = '0;
            for (int i = SQ_SZ-1; i >= 1; --i) begin
                if (ok_table_rotr_T[j][i]) begin
                    ok_youngest_sel_rotr_T[j][i] = 1'b1;
                    break;
                end
            end
        end
    end

    for (genvar j = 0; j < 4; ++j) begin
        logic [DSQ_SZ-1:0] ok_youngest_sel_ddTj;
        assign ok_youngest_sel_ddTj = {ok_youngest_sel_rotr_T[j], ok_youngest_sel_rotr_T[j]} << ld_in_sq_idx;
        assign ok_youngest_sel_T[j] = ok_youngest_sel_ddTj[DSQ_SZ-1:SQ_SZ];
        // for (genvar i = 0; i < SQ_SZ; ++i) begin
        //     assign ok_youngest_sel[i][j] = ok_youngest_sel_T[j][i];
        // end
    end

    // logic ldb_vld;
    LDB ldb_n;
    // assign ld_out.ldb = ldb;
    // assign ldb_n.en         = ld_in.dispatch_en; // FIXME: can actually disable if no forwardable bytes (but not incorrect either way)
    assign ldb_n.vld_byte_mask  = ld_out.has_byte_mask;
    assign ldb_n.lbuf_idx   = ld_in.lbuf_idx;
    for (genvar j = 0; j < 4; ++j) begin
        always_comb begin
            for (int i = 0; i < SQ_SZ; ++i)
                if (ok_youngest_sel_T[j][i])
                    ldb_n.dat.byte_level[j] = state[i].dat.byte_level[j];
        end
    end
    flop #(
        .WIDTH($bits(LDB))
    ) ldb_flop (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),
        .clmsk  (clmsk),

        .i_vld  (ld_in.dispatch_en),
        .i_msk  (ld_in.msk),
        .i_dat  (ldb_n),

        .o_vld  (ld_out.ldb_vld),
        .o_msk  (),
        .o_dat  (ld_out.ldb)
    );

    // issue
    // sq2rs rs_out_n;
    for (genvar i = 0; i < RS_LOD_SZ; ++i) begin
        logic[SQ_SZ-1:0] cur_vld_older;
        assign cur_vld_older = compute_range_mask(head, rs_in.dsq_idx[i]);
        assign rs_out.any_older_ncpl_store[i] = |(cur_vld_older & ncpl);
    end

`ifdef DEBUG
    task print_sq;
        logic [SQ_SZ-1:0] sq_vld;

        $display("  | >> SQ >>");
        $display("ld_in : dsq_idx: %2d, lbuf_idx: %1d, addr: %x, size: %d, dispatch_en: %b",
            ld_in.dsq_idx,
            ld_in.lbuf_idx,
            ld_in.addr,
            ld_in.size,
            ld_in.dispatch_en
        );

        $display("ld_out: has_byte_mask: %b, any_older_ncpl_store: %b, ldb: {vld: %b, vld_byte_mask: %b, lbuf_idx: %1d, dat: %x}",
            ld_out.has_byte_mask,
            ld_out.any_older_ncpl_store,
            ld_out.ldb_vld,
            ld_out.ldb.vld_byte_mask,
            ld_out.ldb.lbuf_idx,
            ld_out.ldb.dat
        );
        $display("query_word:   %x", query_word);
        $display("vld_older:    %b", vld_older);
        $display("match_word:   %b", match_word);
        for (int i = 0; i < 4; ++i)
            $display("byte_mask_table_T[%1d]: %b", i, byte_mask_table_T[i]);
        for (int i = 0; i < 4; ++i)
            $display("ok_table_T[%1d]:        %b", i, ok_table_T[i]);
        for (int i = 0; i < 4; ++i)
            $display("ok_table_rotr_T[%1d]:   %b", i, ok_table_rotr_T[i]);
        for (int i = 0; i < 4; ++i)
            $display("ok_youngest_sel_T[%1d]: %b", i, ok_youngest_sel_T[i]);


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

            $display("SQ[%2d]: {used: %b, cpl: %b}, dst: %x, size: %1d, byte_mask: %b, dat: %x",
                i,
                hdr.used[i],
                // hdr.pol[i],
                hdr.cpl[i],
                state[i].dst,
                state[i].size,
                state[i].byte_mask,
                state[i].dat
            );
        end

        $display("  | << SQ <<");
    endtask

`endif


endmodule
