`include "sys_defs.svh"
`include "execute.svh"

module lod_ex(
`ifdef DEBUG
    input               print_en,
`endif
    input               clock,
    input               reset,
    input               flush,
    input   BMASK       clmsk,
    input   SMASK       cpl_smask,

    /* FRONTEND */
    output  logic       i_rdy,  // ready to accept from regs.o_dat.lod?
    input   logic       i_vld,  // insns to accept from regs.o_dat.lod
    input   LOD_REGS    i_regs, // insn metadata/operands
    input   BMASK       i_msk,
    
    // input   sq2execute                  sq_in,
    // output  execute2sq                  sq_out,
    // output  execute2lq                  lq_out,
    // output  executeLD2sq                ld_sq_out,

    input   sq2ld       sq_in,
    output  ld2sq       sq_out,
    input   dcache2ld   dcache_in,
    output  ld2dcache   dcache_out,

    output  LMASK                   cpl_l1hot,
    output  execute2complete_lod    clod_out,

    /* Early CDB arbitration */
    output  logic           cdb_req,
    output  BMASK           ctag_msks,
    output  PHYS_REG_IDX    ctag_ts,
    input   logic           cdb_gnt,

    /* BACKEND */
    output  logic           o_cands_vld,
    output  BMASK           o_cands_msk,
    output  CPL_CAND        o_cands
);
    initial begin
        assert(NUM_FU_LOD == 1) else $fatal("lod_ex impl hardcoded to NUM_FU_LOD == 1");
        assert(LBUF_SZ >= LQ_SZ)else $fatal;
    end

    typedef struct packed {
        // logic           vld;
        // BMASK           msk;

        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;

        // byte access information
        logic           rd_unsigned;
        ADDR            addr;
        MEM_SIZE        mem_size;

        // readiness
        DSQ_IDX         dsq_idx;
        LQ_IDX          lq_idx;
        logic [3:0]     need_byte_mask;
    } QUERY_BAY_ENTRY;

    logic           bay_vld;
    BMASK           bay_msk;
    QUERY_BAY_ENTRY i_bay_dat, bay_dat;
    logic           dispatch_en;
    logic           bay_need;

    // always prioritize replays over new loads 
    logic           bay_ingress_rdy;
    logic           replay2bay_vld;
    BMASK           replay2bay_msk;
    QUERY_BAY_ENTRY replay2bay_dat;
    logic           bay2replay_rdy;

    assign i_rdy            = bay_ingress_rdy & ~replay2bay_vld;
    assign bay2replay_rdy   = bay_ingress_rdy;

    ppln_skid #(
        .WIDTH($bits(QUERY_BAY_ENTRY))
    ) query_bay (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),
        .clmsk  (clmsk),

        .i_vld  (replay2bay_vld | i_vld),
        .i_rdy  (bay_ingress_rdy),
        .i_msk  (replay2bay_vld ? replay2bay_msk : i_msk),
        .i_dat  (replay2bay_vld ? replay2bay_dat : i_bay_dat),

        .o_vld  (bay_vld),
        .o_rdy  (dispatch_en),
        .o_msk  (bay_msk),
        .o_dat  (bay_dat)
    );
    assign bay_need = |(bay_dat.need_byte_mask);

    typedef struct packed {
        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;

        // replay control
        SMASK           older_ncpl_store_mask;
        logic           replay; // load-order violation i.e. completed before an older matching store?

        // byte access information
        logic           rd_unsigned;
        ADDR            addr; // TODO: dont use ADDR anywhere; they are unnecessarily **expensive** (we cannot index that much memory)
        logic [1:0]     iw_off;
        MEM_SIZE        mem_size;
        DATA_BLOCK      raw;

        DSQ_IDX         dsq_idx;
        LQ_IDX          lq_idx;
        logic[3:0]      need_byte_mask;
        logic           satisfied;
    } LOAD_BUFFER_ENTRY;

    struct packed {
        logic   vld;
        BMASK   msk;
    } [LBUF_SZ-1:0] lbuf_hdr, lbuf_hdr_n;
    LOAD_BUFFER_ENTRY [LBUF_SZ-1:0] lbuf, lbuf_n;
    logic             [LBUF_SZ-1:0] lbuf_vld;
    logic             [LBUF_SZ-1:0] lbuf_kill;
    logic             [LBUF_SZ-1:0] lbuf_need;
    logic             [LBUF_SZ-1:0] lbuf_any_older_ncpl_store;
    logic             [LBUF_SZ-1:0] lbuf_replay;

    for (genvar i = 0; i < LBUF_SZ; ++i) begin
        assign lbuf_vld[i] = lbuf_hdr[i].vld;
        assign lbuf_kill[i]= flush & |(lbuf_hdr[i].msk & clmsk);
        // assign lbuf_need[i]= |(lbuf[i].need_byte_mask);
        assign lbuf_need[i]= ~lbuf[i].satisfied;
        assign lbuf_any_older_ncpl_store[i] = |lbuf[i].older_ncpl_store_mask;
        assign lbuf_replay[i] = lbuf[i].replay;
    end

    /* In -> Bay */
    ADDR            i_addr;
    DATA_BYTE_MASK  i_byte_mask;
    assign i_addr   = i_regs.rs1 + i_regs.dat.opb; // load address computation
    assign i_byte_mask  = compute_byte_mask(i_addr, i_regs.dat.mem_size);

    /* Bay -> Lbuf ("dispatch") */
    // FIXME: Change lbuf to a compressible ring buffer to avoid crossbar
    logic dcache_hit;
    logic [LBUF_SZ-1:0] dispatch_rdy_req, dispatch_rdy_gnt;
    LBUF_IDX dispatch_rdy_idx;
    logic [LBUF_SZ-1:0] dispatch_lbuf_en;

    assign dcache_hit = (dcache_in.status == LD_SUCC);  // TODO: Can change in the future, where an MSHR-allocate on a miss shall still be considered "success".
    assign dispatch_rdy_req = ~(lbuf_vld & ~lbuf_kill); // TODO: also reflect same-cycle frees due to "to-issue" (i.e. got CDB reservation)
    psel_gen #(
        .WIDTH  (LBUF_SZ),
        .REQS   (1)
    ) dispatch_rdy_sel (
        .req    (dispatch_rdy_req),
        .gnt_bus(dispatch_rdy_gnt)
    );
    always_comb begin
        dispatch_rdy_idx    = '0;
        for (int i = 0; i < LBUF_SZ; ++i) begin
            if (dispatch_rdy_gnt[i])
                dispatch_rdy_idx = i;
        end
    end

    logic sq_satisfies_bay;
    assign sq_satisfies_bay = ~|(bay_need & ~sq_in.has_byte_mask);
    assign dispatch_en      =
        bay_vld
    // &   ~sq_in.any_older_ncpl_store // RAW hazard
    &   (sq_satisfies_bay | dcache_hit)
    &   |dispatch_rdy_req;
    assign dispatch_lbuf_en =
        {LBUF_SZ{
            bay_vld
        // &   ~sq_in.any_older_ncpl_store
        &   (sq_satisfies_bay | dcache_hit)
        }}
    &   dispatch_rdy_gnt;

    assign clod_out.en  = dispatch_en;
    assign clod_out.msk = bay_msk;
    always_comb begin
        cpl_l1hot = '0;
        if (dispatch_en)
            cpl_l1hot[bay_dat.lq_idx] = 1'b1;
    end

    /* Lbuf -> CDB shr */
    logic [LBUF_SZ-1:0] lbuf2cdb_arb_req; // request to request for cdb slot
    logic [LBUF_SZ-1:0] lbuf2cdb_arb_gnt; // grant   to request for cdb slot
    // cdb_gnt = did the chosen lbuf requestor actually get a cdb slot
    assign lbuf2cdb_arb_req = (lbuf_vld & ~lbuf_kill) & ~lbuf_need & ~lbuf_any_older_ncpl_store & ~lbuf_replay;
    psel_gen #(
        .WIDTH  (LBUF_SZ),
        .REQS   (1)
    ) cdb_arb_sel (
        .req    (lbuf2cdb_arb_req),
        .gnt    (lbuf2cdb_arb_gnt)
    );

    assign cdb_req = |lbuf2cdb_arb_req;
    always_comb begin
        ctag_msks   = '0;
        ctag_ts     = '0;
        for (int i = 0; i < LBUF_SZ; ++i) begin
            if (lbuf2cdb_arb_gnt[i]) begin
                ctag_msks   = lbuf_hdr[i].msk & ~clmsk;
                ctag_ts     = lbuf[i].t;
            end
        end
    end

    logic [LBUF_SZ-1:0] lbuf2replay_arb_req;
    logic [LBUF_SZ-1:0] lbuf2replay_arb_gnt;
    logic           lbuf2replay_vld, replay2lbuf_rdy;
    BMASK           lbuf2replay_msk;
    QUERY_BAY_ENTRY lbuf2replay_dat;
    assign lbuf2replay_arb_req  = (lbuf_vld & ~lbuf_kill) & lbuf_replay; 
    assign lbuf2replay_vld      = |lbuf2replay_arb_req;

    psel_gen #(
        .WIDTH  (LBUF_SZ),
        .REQS   (1)
    ) replay_arb_sel (
        .req    (lbuf2replay_arb_req),
        .gnt    (lbuf2replay_arb_gnt)
    );

    always_comb begin
        for (int i = 0; i < LBUF_SZ; ++i) begin
            LOAD_BUFFER_ENTRY cur;
            cur = lbuf[i];

            if (lbuf2replay_arb_gnt[i]) begin
                lbuf2replay_msk = lbuf_hdr[i].msk & ~clmsk;
                lbuf2replay_dat = {
                    t               : cur.t,
                    rob_idx         : cur.rob_idx,

                    rd_unsigned     : cur.rd_unsigned,
                    addr            : cur.addr,
                    mem_size        : cur.mem_size,

                    dsq_idx         : cur.dsq_idx,
                    lq_idx          : cur.lq_idx,
                    need_byte_mask  : cur.need_byte_mask
                };
            end
        end
    end

    ppln_skid #(
        .WIDTH($bits(QUERY_BAY_ENTRY))
    ) replay_buf (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),
        .clmsk  (clmsk),

        .i_vld  (lbuf2replay_vld),
        .i_rdy  (replay2lbuf_rdy),
        .i_msk  (lbuf2replay_msk),
        .i_dat  (lbuf2replay_dat),

        .o_vld  (replay2bay_vld),
        .o_rdy  (bay2replay_rdy),
        .o_msk  (replay2bay_msk),
        .o_dat  (replay2bay_dat)
    );


    /* Query + forward handling */
    // only let the query ask dcache... *1*
    assign dcache_out = '{
        vld         : bay_vld & bay_need,
        // vld         : bay_vld & bay_need & ~sq_in.any_older_ncpl_store,
        msk         : bay_msk,
        lbuf_idx    : dispatch_rdy_idx,
        addr        : bay_dat.addr,

        dispatch_en : dispatch_en & ~sq_satisfies_bay
    };

    assign sq_out = '{
        dsq_idx     : bay_dat.dsq_idx,
        lbuf_idx    : dispatch_rdy_idx,
        addr        : bay_dat.addr,
        size        : bay_dat.mem_size,

        dispatch_en : dispatch_en,
        msk         : bay_msk
    };

    // i_regs->bay logic
    assign i_bay_dat = '{
        t               : i_regs.dat.t,
        rob_idx         : i_regs.dat.rob_idx,
        rd_unsigned     : i_regs.dat.rd_unsigned,
        addr            : i_addr,
        mem_size        : i_regs.dat.mem_size,
        dsq_idx         : i_regs.dat.dsq_idx,
        lq_idx          : i_regs.dat.lq_idx,
        need_byte_mask  : i_byte_mask
    };

    // always_comb begin
    //     // *1* ...but any bay entry can ask the SQ
    //     ld_sq_out = '0;
    //     foreach (bay[i]) begin
    //         ld_sq_out.forward_req_en    [i] = qry_req[i];
    //         ld_sq_out.forward_addr      [i] = bay[i].addr;
    //         ld_sq_out.forward_mem_size  [i] = bay[i].mem_size; // TODO: REMOVE
    //         ld_sq_out.forward_sq_idx    [i] = bay[i].sq_idx;
    //         ld_sq_out.forward_lq_pair   [i] = bay[i].lq_pair;
    //     end

    //     bay_hdr_n   = bay_hdr;
    //     bay_n       = bay;
    //     // merge dcache result
    //     if (dcache_in.status == LD_SUCC) begin
    //         bay_n.need_byte_mask&= '0;
    //         bay_n.raw           = dcache_in.dat.word_level[bay.addr[2]];
    //     end

    //     if (qry_req[i]) begin
    //         // merge store forwards

    //         bay_n[i].need_byte_mask &= ~sq_in.forward_byte_en[i];
    //         bay_n[i].raw = bytewise_override(
    //             bay_n[i].raw,               // dst
    //             sq_in.forward_data[i],      // src
    //             sq_in.forward_byte_en[i]    // src_byte_mask
    //         );
    //         continue;
    //     end
    // end


    always_comb begin
        DATA_BLOCK coal_dat; // coal(esced)

        lbuf_hdr_n  = lbuf_hdr;
        lbuf_n      = lbuf;

        // TODO: note to self. Moving this was a bug fix! since msk was not cleared, we had spurious kills
        for (int i = 0; i < LBUF_SZ; ++i) begin
            if ((lbuf2cdb_arb_gnt[i] & cdb_gnt) | (lbuf2replay_arb_gnt[i] & replay2lbuf_rdy) | lbuf_kill[i])
                lbuf_hdr_n[i].vld = 1'b0;
            lbuf_hdr_n[i].msk = lbuf_hdr[i].msk & ~clmsk;
        end

        if (dcache_in.ldb_vld)
            coal_dat = dcache_in.ldb.dat;

        if (sq_in.ldb_vld)
            coal_dat = bytewise_override(coal_dat, sq_in.ldb.dat, {4{sq_in.ldb_vld}} & sq_in.ldb.vld_byte_mask);

        if (dcache_in.ldb_vld | sq_in.ldb_vld) begin
            /* TODO/FIXME:
            In this blocking dcache design, a load is dispatched iff all of its
            byte can be satisfied (1. by SQ alone or 2. by SQ and dcache). And so
            need_byte_mask will go to 0 immediately. This will change with a nonblocking
            dcache design, where a load may dispatch to the buffer only partially
            satisfied (and wait for the rest from dcache ldb broadcast). */
            // lbuf_n[dcache_in.ldb.lbuf_idx].need_byte_mask &= '0;
            lbuf_n[dcache_in.ldb.lbuf_idx].raw = coal_dat;
            lbuf_n[dcache_in.ldb.lbuf_idx].satisfied = 1'b1;
        end

        for (int i = 0; i < LBUF_SZ; ++i) begin
            lbuf_n[i].older_ncpl_store_mask = lbuf[i].older_ncpl_store_mask     & ~cpl_smask;
            lbuf_n[i].replay                |=|(lbuf[i].older_ncpl_store_mask   & cpl_smask);

            if (dispatch_lbuf_en[i]) begin
                logic [1:0] iw_off;

                iw_off = 0;
                case (bay_dat.mem_size)
                BYTE: iw_off = bay_dat.addr[1:0];
                HALF: iw_off = bay_dat.addr[1];
                default:;
                endcase

                lbuf_hdr_n[i] = '{
                    vld : 1'b1,
                    msk : bay_msk
                };

                lbuf_n[i] = '{
                    t           : bay_dat.t,
                    rob_idx     : bay_dat.rob_idx,

                    older_ncpl_store_mask   : sq_in.older_ncpl_store_mask,
                    replay                  : |(sq_in.older_ncpl_store_mask & cpl_smask),

                    rd_unsigned : bay_dat.rd_unsigned,
                    addr        : bay_dat.addr,
                    iw_off      : iw_off,
                    mem_size    : bay_dat.mem_size,
                    raw         : '0,

                    dsq_idx         : bay_dat.dsq_idx,
                    lq_idx          : bay_dat.lq_idx,
                    need_byte_mask  : bay_dat.need_byte_mask,
                    satisfied       : 1'b0
                };
            end
        end

    end

    logic       lbuf2cands0_vld;
    BMASK       lbuf2cands0_msk;
    CPL_CAND    lbuf2cands0_dat;
    assign lbuf2cands0_vld = |lbuf2cdb_arb_gnt & cdb_gnt;
    always_comb begin
        lbuf2cands0_msk     = '0;
        lbuf2cands0_dat     = '0;

        for (int i = 0; i < LBUF_SZ; ++i) begin
            LOAD_BUFFER_ENTRY   tmp;
            logic               sign;
            DATA_BLOCK          blk;

            tmp = lbuf[i];
            sign= 1'b0;
            case (tmp.mem_size)
            BYTE: sign = tmp.raw.byte_level[tmp.iw_off][7];
            HALF: sign = tmp.raw.half_level[tmp.iw_off][15];
            default:;
            endcase

            blk = tmp.rd_unsigned ? '0 : {(32){sign}};
            case (tmp.mem_size)
            BYTE: blk.byte_level[0] = tmp.raw.byte_level[tmp.iw_off];
            HALF: blk.half_level[0] = tmp.raw.half_level[tmp.iw_off];
            default: blk.word_level = tmp.raw.word_level;
            endcase

            if (lbuf2cdb_arb_gnt[i] && cdb_gnt) begin
                lbuf2cands0_dat.t       = tmp.t;
                lbuf2cands0_dat.rob_idx = tmp.rob_idx;
                lbuf2cands0_dat.data    = blk;

                lbuf2cands0_msk         = lbuf_hdr[i].msk & ~clmsk;
            end
        end
    end

    logic       cands02cands1_vld;
    BMASK       cands02cands1_msk;
    CPL_CAND    cands02cands1_dat;
    flop #(
        .FLUSH_MODE (SKID_FLUSH_MASK),
        .WIDTH      ($bits(CPL_CAND))
    ) cands0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),
        .clmsk  (clmsk),

        .i_vld  (lbuf2cands0_vld),
        .i_msk  (lbuf2cands0_msk),
        .i_dat  (lbuf2cands0_dat),

        .o_vld  (cands02cands1_vld),
        .o_msk  (cands02cands1_msk),
        .o_dat  (cands02cands1_dat)
    );

    logic       cands1_vld;
    BMASK       cands1_msk;
    CPL_CAND    cands1_dat;
    flop #(
        .FLUSH_MODE (SKID_FLUSH_MASK),
        .WIDTH      ($bits(CPL_CAND))
    ) cands1 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),
        .clmsk  (clmsk),

        .i_vld  (cands02cands1_vld),
        .i_msk  (cands02cands1_msk),
        .i_dat  (cands02cands1_dat),

        .o_vld  (cands1_vld),
        .o_msk  (cands1_msk),
        .o_dat  (cands1_dat)
    );

    assign o_cands_vld = cands1_vld;
    assign o_cands_msk = cands1_msk;
    assign o_cands = '{
        t       : cands1_dat.t,
        rob_idx : cands1_dat.rob_idx,
        data    : cands1_dat.data
    };

    always_ff @(posedge clock) begin
        lbuf_hdr    <= lbuf_hdr_n;
        lbuf        <= lbuf_n;

        if (reset)
            lbuf_hdr<= '0;
    end

`ifdef FORMAL
    logic either_ldb_en;
    LBUF_IDX ldb_tgt;
    logic[3:0] coal_byte_mask;
    assign either_ldb_en = dcache_in.ldb_vld | sq_in.ldb_vld;
    assign ldb_tgt = dcache_in.ldb_vld ? dcache_in.ldb.lbuf_idx : sq_in.ldb.lbuf_idx;
    assign coal_byte_mask =
        {4{dcache_in.ldb_vld}}   & dcache_in.ldb.vld_byte_mask
    |   {4{sq_in.ldb_vld}}       & sq_in.ldb.vld_byte_mask;
    always_ff @(posedge clock) begin
        // Invariant 1: dcache and sq, if both enabled, broadcast to the same load buffer index
        assert(reset | ~(dcache_in.ldb_vld & sq_in.ldb_vld) | (dcache_in.ldb.lbuf_idx == sq_in.ldb.lbuf_idx)) else $fatal;

        // Invariant 2: ldb target (load buffer entry) must be valid
        assert(reset | ~either_ldb_en | lbuf_hdr[ldb_tgt].vld) else $fatal;

        // Invariant 3: the coalesced result of the dcache + sq ldb's will fully satisfy the target load
        // (we do not yet allow loads to dispatch only partially satisfied)
        assert(reset | ~either_ldb_en | ~|(lbuf[ldb_tgt].need_byte_mask & ~coal_byte_mask));

        // assert(reset | ~sq_in.ldb_vld);
    end
`endif

`ifdef DEBUG
task print_lod_ex();
    $display("\n[%0t] <<< lod_ex DEBUG >>>", $time);
    $display("  flush: %b, clmsk: %b", flush, clmsk);
    $display("  i_vld = %b | i_rdy = %b", i_vld, i_rdy);
    $display("  dispatch_lbuf_en   = %b", dispatch_lbuf_en);
    $display("  cdb_req = %b | cdb_gnt = %b", cdb_req, cdb_gnt);
    $display("  lbuf2cdb_arb_gnt= %b", lbuf2cdb_arb_gnt);
    $display("  ctag_ts     = %2d", ctag_ts);

    $display("  -- BAY STATE --");
    // for (int i = 0; i < NUM_FU_LOD; ++i) begin
    //     if (!bay_hdr[i].vld) begin
    //         $display("bay[%2d]: ", i);
    //         continue;
    //     end
    //     $display("bay[%2d]: vld=%b rob_idx=%3d t=%2d addr=0x%08x size=%s unsign=%b nbm=%b raw=%h",
    //         i,
    //         bay_hdr[i].vld,
    //         bay[i].rob_idx,
    //         bay[i].t,
    //         bay[i].addr,
    //         dbg_mem_size(bay[i].mem_size),
    //         bay[i].rd_unsigned,
    //         bay[i].need_byte_mask,
    //         bay[i].raw
    //     );
    // end
    if (!i_vld)
        $display("i_bay_dat:");
    else
        $display("i_bay_dat: vld=%b msk=%b rob_idx=%3d t=%2d addr=0x%08x size=%s unsign=%b nbm=%b",
            i_vld,
            i_msk,
            i_bay_dat.rob_idx,
            i_bay_dat.t,
            i_bay_dat.addr,
            dbg_mem_size(i_bay_dat.mem_size),
            i_bay_dat.rd_unsigned,
            i_bay_dat.need_byte_mask
        );

    if (!bay_vld)
        $display("bay: ");
    else
        $display("bay_dat  : vld=%b msk=%b rob_idx=%3d t=%2d addr=0x%08x size=%s unsign=%b nbm=%b",
            bay_vld,
            bay_msk,
            bay_dat.rob_idx,
            bay_dat.t,
            bay_dat.addr,
            dbg_mem_size(bay_dat.mem_size),
            bay_dat.rd_unsigned,
            bay_dat.need_byte_mask
        );
    $display("sq_in : has_byte_mask: %b, any_older_ncpl_store: %b, ldb: {en: %b, vld_byte_mask: %b, lbuf_idx: %1d, dat: %x}",
        sq_in.has_byte_mask,
        sq_in.any_older_ncpl_store,
        sq_in.ldb_vld,
        sq_in.ldb.vld_byte_mask,
        sq_in.ldb.lbuf_idx,
        sq_in.ldb.dat
    );

    $display("sq_out: dsq_idx: %2d, lbuf_idx: %1d, addr: %x, size: %d, dispatch_en: %b",
        sq_out.dsq_idx,
        sq_out.lbuf_idx,
        sq_out.addr,
        sq_out.size,
        sq_out.dispatch_en
    );

    $display("dcache_out: vld: %b, lbuf_idx: %1d, addr: 0x%x, dispatch_en: %b",
        dcache_out.vld,
        dcache_out.lbuf_idx,
        dcache_out.addr,
        dcache_out.dispatch_en
    );
    $display("dcache_in : status: %s, ldb: {en: %b, lbuf_idx: %1d, dat: 0x%x}",
        dbg_ld_status(dcache_in.status),
        dcache_in.ldb_vld,
        dcache_in.ldb.lbuf_idx,
        dcache_in.ldb.dat
    );

    // for (int i = 0; i < NUM_FU_LOD; ++i) begin
    //     $display("sq_in[%1d]: qry_req=%b, byte_en=%b, raw=%x",
    //         i,
    //         qry_req[i],
    //         sq_in.forward_byte_en[i],
    //         sq_in.forward_data[i],
    //     );
    // end


    // for (int i = 0; i < NUM_FU_LOD; ++i)
    //     $display("dispatch_lbuf_en_bay2buf[%1d]: %b", i, dispatch_lbuf_en_bay2buf[i]);
    $display("dispatch_lbuf_en: %b", dispatch_lbuf_en);
    $display("dispatch_rdy_req: %b", dispatch_rdy_req);
    $display("dispatch_rdy_gnt: %b", dispatch_rdy_gnt);

    $display("  -- LBUF STATE --");
    $display("flush: %b, clmsk: %b", flush, clmsk);
    for (int i = 0; i < LBUF_SZ; ++i) begin
        if (!lbuf_hdr[i].vld) begin
            $display("lbuf[%2d]: ", i);
            continue;
        end
        $display("lbuf[%2d]: msk=%b, rob_idx=%3d t=%2d iw_off=%2b size=%s unsign=%b raw=%h, nbm=%b, {older_stores: %b, replay: %b}",
            i,
            // lbuf_hdr[i].vld,
            lbuf_hdr[i].msk,
            lbuf[i].rob_idx,
            lbuf[i].t,
            lbuf[i].iw_off,
            dbg_mem_size(lbuf[i].mem_size),
            lbuf[i].rd_unsigned,
            lbuf[i].raw,
            lbuf[i].need_byte_mask,
            lbuf[i].older_ncpl_store_mask,
            lbuf[i].replay
        );
    end
    $display("lbuf_vld: %b, lbuf_kill: %b, lbuf2cdb_arb_gnt: %b", lbuf_vld, lbuf_kill, lbuf2cdb_arb_gnt);

    $display("  -- COMPLETION (CDB OUT) --");
    if (cands02cands1_vld)
        $display("cands_shr[0]: rob_idx=%2d, t=%2d, dat=%x",
            cands02cands1_dat.rob_idx,
            cands02cands1_dat.t,
            cands02cands1_dat.data
        );
    else
        $display("cands_shr[0]:");

    if (cands1_vld)
        $display("cands_shr[1]: rob_idx=%2d, t=%2d, dat=%x",
            cands1_dat.rob_idx,
            cands1_dat.t,
            cands1_dat.data
        );
    else
        $display("cands_shr[1]:");

    
    if (replay2bay_vld)
        $display("replay_buf: msk: %b, rob_idx=%2d, t=%2d",
            replay2bay_msk,
            replay2bay_dat.rob_idx,
            replay2bay_dat.t
        );
    else
        $display("replay_buf:");
    //     $display("bay[%2d]: vld=%b rob_idx=%3d t=%2d addr=0x%08x size=%s unsign=%b nbm=%b raw=%h",
    //         i,
    //         bay_hdr[i].vld,
    //         bay[i].rob_idx,
    //         bay[i].t,
    //         bay[i].addr,
    //         dbg_mem_size(bay[i].mem_size),
    //         bay[i].rd_unsigned,
    //         bay[i].need_byte_mask,
    //         bay[i].raw
    //     );

    // $display("t=%2d, rob_idx=%2d, data=%x",
    //     o_cands.t,
    //     o_cands.rob_idx,
    //     o_cands.data
    // );


    // for (int i = 0; i < 2; ++i) begin
    //     $display("cands_shr_n[%1d]: t=%2d, rob_idx=%2d, dat=%x",
    //         i,
    //         cands_shr_n[i].t,
    //         cands_shr_n[i].rob_idx,
    //         cands_shr_n[i].data
    //     );
    // end
    
    // for (int i = 0; i < 2; ++i) begin
    //     $display("cands_shr[%1d]: t=%2d, rob_idx=%2d, dat=%x",
    //         i,
    //         cands_shr[i].t,
    //         cands_shr[i].rob_idx,
    //         cands_shr[i].data
    //     );
    // end

    $display(">>> END DEBUG <<<\n");
endtask
`endif





    // ADDR        i_addrs;
    // MEM_SIZE    tmp_sizes;

    // always_comb begin
    //     // load address computation
    //     i_addrs = i_regs[0].rs1 + i_regs[0].dat.opb;
    //     tmp_sizes = i_regs[0].dat.mem_size;

    //     lq_out.ld_ex_en     = i_vld;
    //     lq_out.ld_lq_idx    = i_regs[0].dat.lq_idx;
    //     lq_out.ld_addr      = i_addrs;
    //     lq_out.ld_mem_size  = tmp_sizes;
    // end

    // CPL_CAND [1:0] cands_shr;
    // always_comb begin
    //     o_cands = cands_shr[1];
    // end    

    // //LD memory request logic
    // logic req_en, next_req_en;
    // logic [$clog2(`LD_BAY_SZ):0] curr_frwd, next_frwd;
    // logic [LD_BAY_SZ-1:0] next_got;
    // always_comb begin
    //     next_req_en = req_en;
    //     next_frwd = curr_frwd;

    //     if (!req_en || (req_en && (dcache_in.status == LD_SUCC))) begin
    //         next_req_en = 0;
    //         next_frwd = '0;
    //         for (int unsigned i = 0; i < `LD_BAY_SZ; i++) begin
    //             if ((!bays.vld[i]) || bays.got[i] || next_got[i]) continue;

    //             next_req_en = 1;
    //             next_frwd = i;
    //             break;
    //         end
    //     end
    // end

    // always_comb begin
    //     dcache_out = '0;

    //     if (req_en) begin
    //         dcache_out.vld = 1;
    //         dcache_out.addr = bays.addr[curr_frwd];
    //     end
    // end

    // always_ff @(posedge clock) begin
    //     if (reset || flush) begin
    //         req_en <= 0;
    //         curr_frwd <= '0;
    //     end
    //     else begin
    //         req_en <= next_req_en;
    //         curr_frwd <= next_frwd;
    //     end
    // end

    // //ST-LD forwarding request logic
    // always_comb begin
    //     ld_sq_out = '0;
    //     foreach (bays.vld[i]) begin
    //         if (!bays.vld[i] || bays.got[i]) continue;
            
    //         ld_sq_out.forward_req_en[i] = bays.vld[i];
    //         ld_sq_out.forward_addr[i] = bays.addr[i];
    //         ld_sq_out.forward_mem_size[i] = bays.mem_size[i];
    //         ld_sq_out.forward_sq_idx[i] = bays.sq_idx[i];
    //     end
    // end

    // //ST-LD forwarding parsing logic
    // logic [LD_BAY_SZ-1:0][3:0] next_st_frwd_byte_mask;
    // DATA_BLOCK [LD_BAY_SZ-1:0] next_dat;
    // always_comb begin
    //     next_got = bays.got;
    //     next_st_frwd_byte_mask = '0;
    //     next_dat = bays.dat;
    //     for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
    //         if (bays.got[i])
    //             continue;

    //         // if (pending && dcache_data_valid && (i == pending_frwd)) begin

    //         //     next_dat[i] = (dcache_data.word_level[bays.addr[i][2]]) >> bays.addr[i][1:0];
    //         //     next_got[i] = 1;
    //         // end

    //         if (req_en && (dcache_in.status == LD_SUCC) && (i == curr_frwd)) begin
    //             next_dat[i] = (dcache_in.dat.word_level[bays.addr[i][2]]) >> bays.addr[i][1:0];
    //             next_got[i] = 1;
    //         end

    //         // for (int unsigned b = 0; b < 4; ++b) begin
    //         //     if (!sq_in.forward_byte_en[i][b])
    //         //         continue;
    //         //     next_dat[i].byte_level[b] = sq_in.forward_data[i].byte_level[b];
    //         // end

    //         if (sq_in.forward_byte_en[i][0])
    //             next_dat[i].byte_level[0] = sq_in.forward_data[i].byte_level[0];
    //         if (sq_in.forward_byte_en[i][1])
    //             next_dat[i].byte_level[1] = sq_in.forward_data[i].byte_level[1];
    //         if (sq_in.forward_byte_en[i][2])
    //             next_dat[i].byte_level[2] = sq_in.forward_data[i].byte_level[2];
    //         if (sq_in.forward_byte_en[i][3])
    //             next_dat[i].byte_level[3] = sq_in.forward_data[i].byte_level[3];
    //         next_st_frwd_byte_mask[i] = bays.st_frwd_byte_mask[i] | sq_in.forward_byte_en[i];

    //         next_got[i] |= ($countones(next_st_frwd_byte_mask[i]) == (2**bays.mem_size[i]));

    //         if (next_got[i]) begin
    //             if (bays.rd_unsigned[i]) begin
    //                 if (bays.mem_size[i] == BYTE) begin
    //                     next_dat[i][31:8] = '0;
    //                 end else if (bays.mem_size[i] == HALF) begin
    //                     next_dat[i][31:16] = '0;
    //                 end
    //             end
    //             else begin
    //                 if (bays.mem_size[i] == BYTE) begin
    //                     next_dat[i][31:8] = {(24){next_dat[i][7]}};
    //                 end else if (bays.mem_size[i] == HALF) begin
    //                     next_dat[i][31:16] = {(16){next_dat[i][15]}};
    //                 end
    //             end
    //         end

    //             // $display("FORWARDING_OCCURING: %0d, mask: %4b, final_data: %0d, ones: %0d, size: %0d, next_got:%b", sq_in.forward_data[i], sq_in.forward_byte_en[i], next_dat[i],$countones(next_st_frwd_byte_mask),2**bays.mem_size[i],next_got[i]);
    //     end
    // end

    // always_ff @(posedge clock) begin

    //     if (reset || flush) begin
    //         bays <= '0;
    //         cands_shr <= '0;
    //     end else begin
    //         foreach (bay_gnt[i]) begin
    //             if (!(bay_gnt[i] && i_vld))
    //                 continue;

    //             bays.vld     [i] <= 1;
    //             bays.got     [i] <= 0;
    //             bays.t       [i] <= i_regs[0].dat.t;
    //             bays.rob_idx [i] <= i_regs[0].dat.rob_idx;
    //             bays.addr    [i] <= i_addrs;
    //             bays.mem_size[i] <= tmp_sizes;
    //             bays.dat     [i] <= '0;
    //             bays.sq_idx  [i] <= i_regs[0].dat.sq_idx;
    //             bays.st_frwd_byte_mask[i] <= '0;
    //             bays.rd_unsigned[i] <= i_regs[0].dat.rd_unsigned;
    //         end

    //         foreach (next_got[i]) begin
    //             bays.got[i] <= next_got[i];
    //             bays.dat[i] <= next_dat[i];
    //             bays.st_frwd_byte_mask[i] <= next_st_frwd_byte_mask[i];
    //         end

    //         foreach (lbuf2cdb_arb_gnt[i]) begin
    //             if (!(lbuf2cdb_arb_gnt[i] && cdb_gnt))
    //                 continue;
    //             bays.vld     [i] <= 0;
    //             bays.got     [i] <= 0;
    //             bays.t       [i] <= '0;
    //             bays.rob_idx [i] <= '0;
    //             bays.addr    [i] <= '0;
    //             bays.mem_size[i] <= '0;
    //             bays.dat     [i] <= '0;
    //             bays.sq_idx  [i] <= '0;
    //             bays.st_frwd_byte_mask[i] <= '0;

    //             cands_shr[0] <= CPL_CAND'{
    //                 t       : bays.t[i],
    //                 rob_idx : bays.rob_idx[i],
    //                 data    : bays.dat[i]
    //             }; 
    //         end

    //         cands_shr[1] <= cands_shr[0];
    //     end
    // end

    // `ifdef DEBUG
    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("  %3d | >> BAYS", $time);
    //         // $display("MEM_LOAD: %b, %d, %0d, %d", pending, dcache_data_valid, pending_frwd, dcache_data);
    //         // $display("FRWD_EN: %b, %b", sq_in.forward_en, sq_in.forward_byte_en);
    //         // $display("i_rdy: %b, i_vld: %b ", i_rdy, i_vld);
    //         // $display("ocands: t: %2d, rob_idx: %2d, data: %x",
    //         //     o_cands[0].t,
    //         //     o_cands[0].rob_idx,
    //         //     o_cands[0].data
    //         // );
    //         $display("ren: %b", bays.vld & ~bays.got);
    //         foreach (bay_gnt[i]) begin
    //             $display("bays[%2d]: vld=%b, got=%b, t=%2d, rob_idx=%2d, addr=%x, mem_size=%2d, dat=%x",
    //                 i,
    //                 bays.vld    [i],
    //                 bays.got    [i],
    //                 bays.t      [i],
    //                 bays.rob_idx[i],
    //                 bays.addr   [i],
    //                 bays.mem_size[i],
    //                 bays.dat    [i]
    //             );
    //         end
    //         $display("  %3d | << BAYS", $time);
    //     end
    // end
    // `endif

    /* TODO: CAND generation logic. Also, how do we know when
    a load result is ready without an lq2execute line? */
endmodule
