`include "sys_defs.svh"
`include "execute.svh"

function automatic DATA_BLOCK bytewise_override(
    input DATA_BLOCK  dst,
    input DATA_BLOCK  src,
    input logic [3:0] src_byte_mask
);
    DATA_BLOCK rv;
    rv = dst;
    foreach (src.byte_level[b]) begin
        if (!src_byte_mask[b])
            continue;
        rv.byte_level[b] = src.byte_level[b];
    end
    return rv;
endfunction

module lod_ex(
`ifdef DEBUG
    input print_en,
`endif
    input clock,
    input reset,
    input flush,
    input BMASK clmsk,

    /* FRONTEND */
    output logic [NUM_FU_LOD-1:0]       i_rdy,
        // ready to accept from regs.o_dat.lod?
    input  logic [NUM_FU_LOD-1:0]       i_vld,
        // insns to accept from regs.o_dat.lod
    input  LOD_REGS [NUM_FU_LOD-1:0]    i_regs,
        // insn metadata/operands
    input  BMASK [NUM_FU_LOD-1:0]       i_bmask,
    
    // input   sq2execute                  sq_in,
    // output  execute2sq                  sq_out,
    // output  execute2lq                  lq_out,
    // output  executeLD2sq                ld_sq_out,

    input   dcache2ld                   dcache_in,
    output  ld2dcache                   dcache_out,

    /* Early CDB arbitration */
    output logic [NUM_FU_LOD-1:0]       cdb_req,
    output PHYS_REG_IDX [NUM_FU_LOD-1:0]ctag_ts,
    input  logic [NUM_FU_LOD-1:0]       cdb_gnt,

    /* BACKEND */
    output CPL_CAND                     o_cands
);
    localparam LBUF_SZ  = 4;

    typedef struct packed {
        // logic           vld;
        // BMASK           msk;

        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;

        // byte access information
        logic           rd_unsigned;
        ADDR            addr;
        MEM_SIZE        mem_size;
        DATA_BLOCK      raw;

        // readiness
        // LSQ_IDX         sq_idx; // TODO: reenable
        logic [3:0]     need_byte_mask;
    } QUERY_BAY_ENTRY;

    struct packed {
        logic   vld;
        BMASK   msk;
    } [NUM_FU_LOD-1:0] bay_hdr, bay_hdr_n;
    QUERY_BAY_ENTRY [NUM_FU_LOD-1:0] bay, bay_n;
    logic           [NUM_FU_LOD-1:0] bay_vld;
    logic           [NUM_FU_LOD-1:0] bay_need;
    logic           [NUM_FU_LOD-1:0] bay_kill;

    for (genvar i = 0; i < NUM_FU_LOD; ++i) begin
        assign bay_vld[i]   = bay_hdr[i].vld;
        assign bay_need[i]  = |(bay[i].need_byte_mask);
        assign bay_kill[i]  = flush & |(bay_hdr[i].msk & clmsk);
    end

    typedef struct packed {
        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;

        // byte access information
        logic           rd_unsigned;
        logic [1:0]     iw_off;
        MEM_SIZE        mem_size;
        DATA_BLOCK      raw;
    } LOAD_BUFFER_ENTRY;

    struct packed {
        logic   vld;
        BMASK   msk;
    } [LBUF_SZ-1:0] lbuf_hdr, lbuf_hdr_n;
    LOAD_BUFFER_ENTRY [LBUF_SZ-1:0] lbuf, lbuf_n;
    logic             [LBUF_SZ-1:0] lbuf_vld;
    logic             [LBUF_SZ-1:0] lbuf_kill;

    for (genvar i = 0; i < LBUF_SZ; ++i) begin
        assign lbuf_vld[i] = lbuf_hdr[i].vld;
        assign lbuf_kill[i]= flush & |(lbuf_hdr[i].msk & clmsk);
    end

    /* In -> Bay */
    typedef union packed {
        logic [3:0]      byte_level;
        logic [1:0][1:0] half_level;
    } DATA_BYTE_MASK;

    ADDR            [NUM_FU_LOD-1:0] i_addr;
    DATA_BYTE_MASK  [NUM_FU_LOD-1:0] i_byte_mask;

    assign i_rdy    = ~bay_vld | bay_kill;
    for (genvar i = 0; i < NUM_FU_LOD; ++i) begin
        assign i_addr[i] = i_regs[i].rs1 + i_regs[i].dat.opb; // load address computation
        always_comb begin
            i_byte_mask[i] = '0;
            case (i_regs[i].dat.mem_size)
            BYTE: i_byte_mask[i][i_addr[i][1:0]]= '1;
            HALF: i_byte_mask[i][i_addr[i][1]]  = '1;
            WORD: i_byte_mask[i]                = '1;
            endcase
        end
    end

    /* Bay -> Lbuf ("dispatch") */
    // FIXME: Change lbuf to a compressible ring buffer to avoid crossbar
    logic [NUM_FU_LOD-1:0]  dispatch_vld_req, dispatch_vld_gnt;
    logic [LBUF_SZ-1:0] dispatch_rdy_req, dispatch_rdy_gnt;
    logic dispatch_en;
    logic [NUM_FU_LOD-1:0][LBUF_SZ-1:0] dispatch_en_bay2buf;

    assign dispatch_vld_req = (bay_vld & ~bay_kill) & ~bay_need;
    assign dispatch_rdy_req = ~lbuf_vld | lbuf_kill; // TODO: also reflect same-cycle frees due to "to-issue" (i.e. got CDB reservation)
    psel_gen #(
        .WIDTH  (NUM_FU_LOD),
        .REQS   (1)
    ) dispatch_vld_sel (
        .req    (dispatch_vld_req),
        .gnt_bus(dispatch_vld_gnt)
    );

    psel_gen #(
        .WIDTH  (LBUF_SZ),
        .REQS   (1)
    ) dispatch_rdy_sel (
        .req    (dispatch_rdy_req),
        .gnt_bus(dispatch_rdy_gnt)
    );

    assign dispatch_en = |dispatch_vld_gnt && |dispatch_rdy_gnt;
    for (genvar i = 0; i < NUM_FU_LOD; ++i) begin
        for (genvar j = 0; j < LBUF_SZ; ++j) begin
            assign dispatch_en_bay2buf[i][j] = dispatch_vld_gnt[i] & dispatch_rdy_gnt[j];
        end
    end

    /* Lbuf -> CDB shr */
    logic [LBUF_SZ-1:0] lbuf2cdb_gnt;
    psel_gen #(
        .WIDTH  (LBUF_SZ),
        .REQS   (1)
    ) arb_out (
        .req    (lbuf_vld & ~lbuf_kill),
        .gnt    (lbuf2cdb_gnt)
    );

    assign cdb_req = |(lbuf_vld & ~lbuf_kill);
    always_comb begin
        ctag_ts = '0;
        for (int i = 0; i < LBUF_SZ; ++i) begin
            if (lbuf2cdb_gnt[i])
                ctag_ts[0] = lbuf[i].t;
        end
    end


    /* Query + forward handling */
    // only let the query ask dcache... *1*
    assign dcache_out   = '{
        vld     : bay_vld[0] & ~bay_kill[0] & bay_need[0],
        addr    : bay[0].addr
    };

    always_comb begin
        // *1* ...but any bay entry can ask the SQ
        // ld_sq_out = '0;
        // foreach (bay[i]) begin
        //     ld_sq_out.forward_req_en    [i] = qry_req[i];
        //     ld_sq_out.forward_addr      [i] = bay[i].addr;
        //     ld_sq_out.forward_mem_size  [i] = bay[i].mem_size; // TODO: REMOVE
        //     ld_sq_out.forward_sq_idx    [i] = bay[i].sq_idx;
        //     ld_sq_out.forward_lq_pair   [i] = bay[i].lq_pair;
        // end

        bay_hdr_n   = bay_hdr;
        bay_n       = bay;
        // merge dcache result
        if (dcache_in.status == LD_SUCC) begin
            bay_n[0].need_byte_mask &= '0;
            bay_n[0].raw            = dcache_in.dat.word_level[bay[0].addr[2]];
        end

        for (int i = 0; i < NUM_FU_LOD; ++i) begin
            // if (qry_req[i]) begin
            //     // merge store forwards

            //     bay_n[i].need_byte_mask &= ~sq_in.forward_byte_en[i];
            //     bay_n[i].raw = bytewise_override(
            //         bay_n[i].raw,               // dst
            //         sq_in.forward_data[i],      // src
            //         sq_in.forward_byte_en[i]    // src_byte_mask
            //     );
            //     continue;
            // end

            if (i_vld[i] & i_rdy[i]) begin
                // i_regs->bay logic
                bay_hdr_n[i] = '{
                    vld : 1'b1,
                    msk : i_bmask[i]
                };

                bay_n[i] = '{
                    t               : i_regs[i].dat.t,
                    rob_idx         : i_regs[i].dat.rob_idx,
                    rd_unsigned     : i_regs[i].dat.rd_unsigned,
                    addr            : i_addr[i],
                    mem_size        : i_regs[i].dat.mem_size,
                    raw             : '0,
                    // sq_idx          : i_regs[0].dat.sq_idx,
                    need_byte_mask  : i_byte_mask[i]
                };
            end else if (|dispatch_en_bay2buf[i] | bay_kill[i]) begin
                // bay->lbuf logic
                bay_hdr_n[i].vld = 1'b0;
            end

        end
    end


    always_comb begin
        lbuf_hdr_n  = lbuf_hdr;
        lbuf_n      = lbuf;

        foreach (dispatch_en_bay2buf[i, j]) begin
            if (dispatch_en_bay2buf[i][j]) begin
                QUERY_BAY_ENTRY cur;
                logic [1:0] iw_off;

                cur = bay[i];

                iw_off = 0;
                case (cur.mem_size)
                BYTE: iw_off = cur.addr[1:0];
                HALF: iw_off = cur.addr[1];
                default:;
                endcase

                lbuf_hdr_n[j] = '{
                    vld : 1'b1,
                    msk : bay_hdr[i].msk
                };

                lbuf_n[j] = '{
                    t           : cur.t,
                    rob_idx     : cur.rob_idx,
                    rd_unsigned : cur.rd_unsigned,
                    iw_off      : iw_off,
                    mem_size    : cur.mem_size,
                    raw         : cur.raw
                };
            end
        end

        for (int i = 0; i < LBUF_SZ; ++i) begin
            if (lbuf2cdb_gnt[i] | lbuf_kill[i])
                lbuf_hdr_n[i].vld = 1'b0;
        end

    end

    logic       lbuf2cands0_vld;
    BMASK       lbuf2cands0_msk;
    CPL_CAND    lbuf2cands0_dat;
    assign lbuf2cands0_vld = |lbuf2cdb_gnt & cdb_gnt;
    always_comb begin
        lbuf2cands0_msk     = '0;
        lbuf2cands0_dat     = '0;
        // lbuf2cands0_dat.vld = |lbuf2cdb_gnt & cdb_gnt; // NOTE: ignored

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

            if (lbuf2cdb_gnt[i] && cdb_gnt) begin
                lbuf2cands0_dat.t       = tmp.t;
                lbuf2cands0_dat.rob_idx = tmp.rob_idx;
                lbuf2cands0_dat.data    = blk;

                lbuf2cands0_msk         = lbuf_hdr[i].msk;
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
        .o_msk  (),
        .o_dat  (cands1_dat)
    );

    assign o_cands = '{
        vld     : cands1_vld,
        t       : cands1_dat.t,
        rob_idx : cands1_dat.rob_idx,
        data    : cands1_dat.data
    };

    always_ff @(posedge clock) begin
        bay_hdr     <= bay_hdr_n;
        bay         <= bay_n;
        lbuf_hdr    <= lbuf_hdr_n;
        lbuf        <= lbuf_n;

        if (reset) begin
            bay_hdr <= '0;
            lbuf_hdr<= '0;
        end
    end

`ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset && print_en) begin
            $display("\n[%0t] <<< lod_ex DEBUG >>>", $time);
            $display("  flush: %b", flush);
            $display("  bay_gnt  = %b | i_vld = %b | i_rdy = %b", bay_gnt, i_vld, i_rdy);
            $display("  dispatch_en_bay  = %b", dispatch_en_bay2buf);
            $display("  cdb_req = %b | cdb_gnt = %b", cdb_req, cdb_gnt);
            $display("  lbuf2cdb_gnt= %b", lbuf2cdb_gnt);
            $display("  ctag_ts     = %2d", ctag_ts);

            $display("  -- BAY STATE --");
            for (int i = 0; i < NUM_FU_LOD; ++i) begin
                if (!bay_hdr[i].vld) begin
                    $display("bay[%2d]: ", i);
                    continue;
                end
                $display("bay[%2d]: vld=%b rob_idx=%3d t=%2d addr=0x%08x size=%s unsign=%b nbm=%b raw=%h",
                    i,
                    bay_hdr[i].vld,
                    bay[i].rob_idx,
                    bay[i].t,
                    bay[i].addr,
                    dbg_mem_size(bay[i].mem_size),
                    bay[i].rd_unsigned,
                    bay[i].need_byte_mask,
                    bay[i].raw
                );
            end

            $display("dcache_out: qry_req: %b, bay_need: %b, prv_qry=%1d, qry=%1d",
                qry_req,
                bay_need,
                prv_qry,
                qry
            );

            $display("dcache_out: qry=%1d {vld=%b, addr=%x}",
                qry,
                dcache_out.vld,
                dcache_out.addr
            );

            $display("dcache_in : {status=%1d, dat=%x}",
                dcache_in.status,
                dcache_in.dat,
            );

            // for (int i = 0; i < NUM_FU_LOD; ++i) begin
            //     $display("sq_in[%1d]: qry_req=%b, byte_en=%b, raw=%x",
            //         i,
            //         qry_req[i],
            //         sq_in.forward_byte_en[i],
            //         sq_in.forward_data[i],
            //     );
            // end


            for (int i = 0; i < NUM_FU_LOD; ++i)
                $display("dispatch_en_bay2buf[%1d]: %b", i, dispatch_en_bay2buf[i]);
            $display("dispatch_vld_req: %b", dispatch_vld_req);
            $display("dispatch_rdy_req: %b", dispatch_vld_req);

            $display("  -- LBUF STATE --");
            for (int i = 0; i < LBUF_SZ; ++i) begin
                if (!lbuf_hdr[i].vld) begin
                    $display("lbuf[%2d]: ", i);
                    continue;
                end
                $display("lbuf[%2d]: vld=%b rob_idx=%3d t=%2d iw_off=%2b size=%s unsign=%b raw=%h",
                    i,
                    lbuf_hdr[i].vld,
                    lbuf[i].rob_idx,
                    lbuf[i].t,
                    lbuf[i].iw_off,
                    dbg_mem_size(lbuf[i].mem_size),
                    lbuf[i].rd_unsigned,
                    lbuf[i].raw
                );
            end

            $display("  -- COMPLETION (CDB OUT) --");
            $display("t=%2d, rob_idx=%2d, data=%x",
                o_cands.t,
                o_cands.rob_idx,
                o_cands.data
            );

            $display("cands_shr[0]: t=%2d, rob_idx=%2d, dat=%x",
                cands02cands1_dat.t,
                cands02cands1_dat.rob_idx,
                cands02cands1_dat.data
            );

            $display("cands_shr[1]: t=%2d, rob_idx=%2d, dat=%x",
                cands1_dat.t,
                cands1_dat.rob_idx,
                cands1_dat.data
            );

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
        end
    end
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

    //         foreach (lbuf2cdb_gnt[i]) begin
    //             if (!(lbuf2cdb_gnt[i] && cdb_gnt))
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
