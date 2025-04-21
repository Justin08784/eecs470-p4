`include "sys_defs.svh"
`include "execute.svh"

function automatic DATA_BLOCK bytewise_override(
    input DATA_BLOCK  dst,
    input DATA_BLOCK  src,
    input logic [3:0] src_bmask
);
    DATA_BLOCK rv;
    rv = dst;
    foreach (src.byte_level[b]) begin
        if (!src_bmask[b])
            continue;
        rv.byte_level[b] = src.byte_level[b];
    end
    return rv;
endfunction

module lod_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic    i_rdy,
        // ready to accept from regs.o_dat.lod?
    input  logic    i_vld,
        // insns to accept from regs.o_dat.lod
    input  LOD_REGS i_regs,
        // insn metadata/operands
    
    input   sq2execute sq_in,
    // output  execute2sq sq_out,
    output  execute2lq lq_out,
    output  executeLD2sq ld_sq_out,

    input  dcache2ld dcache_in,
    output  ld2dcache dcache_out,

    /* Early CDB arbitration */
    output logic cdb_req,
    output PHYS_REG_IDX ctag_ts,
    input  logic cdb_gnt,

    /* BACKEND */
    output CPL_CAND o_cands
);
    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("i_rdy: %b, i_vld: %b", i_rdy, i_vld);
    //         $display("%b %b %b", lq_out, ld_sq_out, dcache_out);
    //         $display("%b %b %b", cdb_req, ctag_ts, o_cands);

    //     end
    // end
    localparam BAY_SZ = `LD_BAY_SZ;
    localparam BUF_SZ = 4;

    typedef struct packed {
        logic           vld;

        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;

        // byte access information
        logic           rd_unsigned;
        ADDR            addr;
        MEM_SIZE        mem_size;
        DATA_BLOCK      raw;

        // readiness
        LSQ_IDX         sq_idx;
        logic [3:0]     need_byte_mask;
    } QUERY_BAY_ENTRY;

    QUERY_BAY_ENTRY [BAY_SZ-1:0] bay, bay_n;
    logic           [BAY_SZ-1:0] bay_vld;
    logic           [BAY_SZ-1:0] bay_need;

    always_comb begin
        foreach (bay[i]) begin
            bay_vld[i]  = bay[i].vld;
            bay_need[i] = |(bay[i].need_byte_mask);
        end
    end

    localparam LBUF_SZ = 4;
    typedef struct packed {
        logic           vld;

        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;

        // byte access information
        logic           rd_unsigned;
        logic [1:0]     iw_off;
        MEM_SIZE        mem_size;
        DATA_BLOCK      raw;
    } LOAD_BUFFER_ENTRY;

    LOAD_BUFFER_ENTRY [LBUF_SZ-1:0] lbuf, lbuf_n;
    logic             [LBUF_SZ-1:0] lbuf_vld;

    always_comb begin
        foreach (lbuf_vld[i])
            lbuf_vld[i] = lbuf[i].vld;
    end

    /* In -> Bay */
    logic [BAY_SZ-1:0] in2bay_gnt;
    psel_gen #(
        .WIDTH(BAY_SZ),
        .REQS(1)
    ) arb_in (
        .req    (~bay_vld),
        .gnt    (in2bay_gnt)
    );

    typedef union packed {
        logic [3:0]      byte_level;
        logic [1:0][1:0] half_level;
    } DATA_BYTE_MASK;
    struct packed {
        ADDR        addr;
        logic [3:0] need_byte_mask;
    } in_parse;

    always_comb begin
        ADDR tmp_addr;
        DATA_BYTE_MASK tmp_bmask;

        i_rdy   = |in2bay_gnt;
        tmp_addr = i_regs.rs1 + i_regs.dat.opb; // load address computation

        tmp_bmask = '0;
        case (i_regs.dat.mem_size)
        BYTE: tmp_bmask[tmp_addr[1:0]]  = '1;
        HALF: tmp_bmask[tmp_addr[1]]    = '1;
        WORD: tmp_bmask = '1;
        endcase

        in_parse = '{
            addr            : tmp_addr,
            need_byte_mask  : tmp_bmask
        };

        lq_out = '{
            ld_ex_en     : i_vld && i_rdy, // FIXME: or is just i_vld fine?
            ld_lq_idx    : i_regs.dat.lq_idx,
            ld_addr      : in_parse.addr,
            ld_mem_size  : i_regs.dat.mem_size
        };
    end

    /* Bay -> Lbuf */
    // FIXME: Change lbuf to a compressible ring buffer to avoid crossbar
    logic [BAY_SZ-1:0]  dis_vld_req;
    logic [LBUF_SZ-1:0] dis_rdy_req;
    localparam DIS_BUS_SZ = 1;
    logic [DIS_BUS_SZ-1:0][BAY_SZ-1:0]  dis_vld_gbus;
    logic [DIS_BUS_SZ-1:0][LBUF_SZ-1:0] dis_rdy_gbus;

    assign dis_vld_req = bay_vld & ~bay_need;
    assign dis_rdy_req = ~lbuf_vld; // TODO: also reflect same-cycle frees due to "to-issue" (i.e. got CDB reservation)
    psel_gen #(
        .WIDTH  (BAY_SZ),
        .REQS   (DIS_BUS_SZ)
    ) arb_dis_vld (
        .req    (dis_vld_req),
        .gnt_bus(dis_vld_gbus)
    );

    psel_gen #(
        .WIDTH  (LBUF_SZ),
        .REQS   (DIS_BUS_SZ)
    ) arb_dis_rdy (
        .req    (dis_rdy_req),
        .gnt_bus(dis_rdy_gbus)
    );

    logic [DIS_BUS_SZ-1:0]  dis_en;
    logic [BAY_SZ-1:0]      dis_en_bay;
    // logic [LBUF_SZ-1:0] dis_en_buf;
    logic [BAY_SZ-1:0][LBUF_SZ-1:0] dis_en_bay2buf;
    always_comb begin
        foreach (dis_en[i])
            dis_en[i] = |dis_vld_gbus[i] && |dis_rdy_gbus[i];

        dis_en_bay = '0;
        foreach (dis_vld_gbus[i, j]) begin
            if (!dis_en[i])
                continue;
            dis_en_bay[j] |= dis_vld_gbus[i][j];
        end

        for (int bus = 0; bus < DIS_BUS_SZ; ++bus) begin
            foreach (dis_en_bay2buf[i, j])
                dis_en_bay2buf[i][j] = dis_vld_gbus[bus][i] && dis_rdy_gbus[bus][j];
        end
    end



    /* Lbuf -> CDB shr */
    logic [LBUF_SZ-1:0] lbuf2cdb_gnt;
    psel_gen #(
        .WIDTH  (LBUF_SZ),
        .REQS   (1)
    ) arb_out (
        .req    (lbuf_vld),
        .gnt    (lbuf2cdb_gnt)
    );

    always_comb begin
        cdb_req = |lbuf_vld;

        ctag_ts = '0;
        foreach (lbuf2cdb_gnt[i]) begin
            if (!lbuf2cdb_gnt[i])
                continue;
            ctag_ts |= lbuf[i].t;
        end
    end


    /* Dcache query selection */
    logic [$clog2(BAY_SZ)-1:0]
        prv_qry,
        nex_qry,
        qry;
    logic [BAY_SZ-1:0] qry_req, qry_gnt;

    always_comb begin
        qry_req = bay_vld & bay_need;
        nex_qry = 0;
        foreach (qry_gnt[i]) begin
            if (!qry_gnt[i])
                continue;
            nex_qry = i;
            break;
        end

        qry = qry_req[prv_qry]
            ? prv_qry
            : nex_qry;
    end

    psel_gen #(
        .WIDTH  (BAY_SZ),
        .REQS   (1)
    ) qry_sel (
        .req    (qry_req),
        .gnt    (qry_gnt)
    );

    /* Query + forward handling */
    QUERY_BAY_ENTRY  qry_entry;
    always_comb begin
        // only let the query ask dcache
        qry_entry = bay[qry];
        dcache_out = '{
            vld     : qry_req[qry],
            addr    : qry_entry.addr
        };

        // but any bay entry can ask the SQ
        ld_sq_out = '0;
        foreach (bay[i]) begin
            ld_sq_out.forward_req_en  [i] = qry_req[i];
            ld_sq_out.forward_addr    [i] = bay[i].addr;
            ld_sq_out.forward_mem_size[i] = bay[i].mem_size; // TODO: REMOVE
            ld_sq_out.forward_sq_idx  [i] = bay[i].sq_idx;
        end

        bay_n = bay;
        // merge dcache result
        if (dcache_in.status == LD_SUCC) begin
            bay_n[qry].need_byte_mask &= '0;
            bay_n[qry].raw            = dcache_in.dat.word_level[qry_entry.addr[2]];
        end

        foreach (bay_n[i]) begin
            if (qry_req[i]) begin
                // merge store forwards

                bay_n[i].need_byte_mask &= ~sq_in.forward_byte_en[i];
                bay_n[i].raw = bytewise_override(
                    bay_n[i].raw,               // dst
                    sq_in.forward_data[i],      // src
                    sq_in.forward_byte_en[i]    // src_bmask
                );
                continue;
            end

            if (in2bay_gnt[i] && i_vld) begin
                // in->bay logic

                bay_n[i] = '{
                    vld     : 1,
                    t       : i_regs.dat.t,
                    rob_idx : i_regs.dat.rob_idx,
                    addr    : in_parse.addr,
                    mem_size: i_regs.dat.mem_size,
                    raw     : '0,
                    sq_idx  : i_regs.dat.sq_idx,
                    need_byte_mask  : in_parse.need_byte_mask,
                    rd_unsigned     : i_regs.dat.rd_unsigned
                };

                continue;
            end 


            // bay->lbuf logic
            if (dis_en_bay[i])
                bay_n[i].vld = 0;

        end
    end


    always_comb begin
        QUERY_BAY_ENTRY cur;
        logic [1:0] iw_off;

        lbuf_n = lbuf;

        foreach (lbuf_n[i]) begin
            if (!lbuf2cdb_gnt[i])
                continue;
            lbuf_n[i].vld = 0;
        end

        foreach (dis_en_bay2buf[i, j]) begin
            if (!dis_en_bay2buf[i][j])
                continue;
            cur = bay[i];

            iw_off = 0;
            case (cur.mem_size)
            BYTE: iw_off = cur.addr[1:0];
            HALF: iw_off = cur.addr[1];
            default:;
            endcase

            lbuf_n[j] = '{
                vld         : 1,
                t           : cur.t,
                rob_idx     : cur.rob_idx,
                rd_unsigned : cur.rd_unsigned,
                iw_off      : iw_off,
                mem_size    : cur.mem_size,
                raw         : cur.raw
            };
        end
    end


    CPL_CAND [1:0] cands_shr, cands_shr_n;
    always_comb begin
        LOAD_BUFFER_ENTRY tmp;
        logic sign;
        DATA_BLOCK o_dat;

        cands_shr_n[0] = '0;
        cands_shr_n[1] = cands_shr[0];
        foreach (lbuf2cdb_gnt[i]) begin
            if (!(lbuf2cdb_gnt[i] && cdb_gnt))
                continue;

            tmp = lbuf[i];
            sign = 0;
            case (tmp.mem_size)
            BYTE: sign = tmp.raw[7];
            HALF: sign = tmp.raw[15];
            default:;
            endcase

            o_dat = tmp.rd_unsigned ? '0 : {(32){sign}};
            case (tmp.mem_size)
            BYTE: o_dat.byte_level[0] = tmp.raw.byte_level[tmp.iw_off];
            HALF: o_dat.half_level[0] = tmp.raw.half_level[tmp.iw_off];
            default: o_dat.word_level = tmp.raw.word_level;
            endcase

            cands_shr_n[0] = CPL_CAND'{
                t       : tmp.t,
                rob_idx : tmp.rob_idx,
                data    : o_dat
            }; 
        end

        o_cands = cands_shr[1];
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            prv_qry     <= '0;
            bay         <= '0;
            lbuf        <= '0;
            cands_shr   <= '0;
        end else begin
            if (bay_need[qry])
                prv_qry <= qry;
            bay         <= bay_n;
            lbuf        <= lbuf_n;
            cands_shr   <= cands_shr_n;
        end
    end

`ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("\n[%0t] <<< lod_ex DEBUG >>>", $time);
            $display("  flush: %b", flush);
            $display("  in2bay_gnt  = %b | i_vld = %b | i_rdy = %b", in2bay_gnt, i_vld, i_rdy);
            $display("  dis_en_bay  = %b", dis_en_bay);
            $display("  cdb_req = %b | cdb_gnt = %b", cdb_req, cdb_gnt);
            $display("  lbuf2cdb_gnt= %b", lbuf2cdb_gnt);
            $display("  ctag_ts     = %2d", ctag_ts);

            $display("  -- BAY STATE --");
            for (int i = 0; i < BAY_SZ; ++i) begin
                if (!bay[i].vld) begin
                    $display("bay[%2d]: ", i);
                    continue;
                end
                $display("bay[%2d]: vld=%b rob_idx=%3d t=%2d addr=0x%08x size=%s unsign=%b nbm=%b raw=%h",
                    i,
                    bay[i].vld,
                    bay[i].rob_idx,
                    bay[i].t,
                    bay[i].addr,
                    dbg_mem_size(bay[i].mem_size),
                    bay[i].rd_unsigned,
                    bay[i].need_byte_mask,
                    bay[i].raw
                );
            end
            $display("dcache_out: qry=%1d {vld=%b, addr=%x}",
                qry,
                dcache_out.vld,
                dcache_out.addr
            );

            $display("dcache_in : {status=%1d, dat=%x}",
                dcache_in.status,
                dcache_in.dat,
            );

            for (int i = 0; i < BAY_SZ; ++i) begin
                $display("sq_in[%1d]: qry_req=%b, byte_en=%b, raw=%x",
                    i,
                    qry_req[i],
                    sq_in.forward_byte_en[i],
                    sq_in.forward_data[i],
                );
            end


            for (int i = 0; i < BAY_SZ; ++i)
                $display("dis_en_bay2buf[%1d]: %b", i, dis_en_bay2buf[i]);
            $display("dis_vld_req: %b", dis_vld_req);
            $display("dis_rdy_req: %b", dis_vld_req);

            $display("  -- LBUF STATE --");
            for (int i = 0; i < LBUF_SZ; ++i) begin
                if (!lbuf[i].vld) begin
                    $display("lbuf[%2d]: ", i);
                    continue;
                end
                $display("lbuf[%2d]: vld=%b rob_idx=%3d t=%2d iw_off=%2b size=%s unsign=%b raw=%h",
                    i,
                    lbuf[i].vld,
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

            for (int i = 0; i < 2; ++i) begin
                $display("cands_shr_n[%1d]: t=%2d, rob_idx=%2d, dat=%x",
                    i,
                    cands_shr_n[i].t,
                    cands_shr_n[i].rob_idx,
                    cands_shr_n[i].data
                );
            end
            
            for (int i = 0; i < 2; ++i) begin
                $display("cands_shr[%1d]: t=%2d, rob_idx=%2d, dat=%x",
                    i,
                    cands_shr[i].t,
                    cands_shr[i].rob_idx,
                    cands_shr[i].data
                );
            end

            $display(">>> END DEBUG <<<\n");
        end
    end
`endif





    // ADDR        tmp_addrs;
    // MEM_SIZE    tmp_sizes;

    // always_comb begin
    //     // load address computation
    //     tmp_addrs = i_regs.rs1 + i_regs.dat.opb;
    //     tmp_sizes = i_regs.dat.mem_size;

    //     lq_out.ld_ex_en     = i_vld;
    //     lq_out.ld_lq_idx    = i_regs.dat.lq_idx;
    //     lq_out.ld_addr      = tmp_addrs;
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
    //         foreach (in2bay_gnt[i]) begin
    //             if (!(in2bay_gnt[i] && i_vld))
    //                 continue;

    //             bays.vld     [i] <= 1;
    //             bays.got     [i] <= 0;
    //             bays.t       [i] <= i_regs.dat.t;
    //             bays.rob_idx [i] <= i_regs.dat.rob_idx;
    //             bays.addr    [i] <= tmp_addrs;
    //             bays.mem_size[i] <= tmp_sizes;
    //             bays.dat     [i] <= '0;
    //             bays.sq_idx  [i] <= i_regs.dat.sq_idx;
    //             bays.st_frwd_byte_mask[i] <= '0;
    //             bays.rd_unsigned[i] <= i_regs.dat.rd_unsigned;
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
    //         foreach (in2bay_gnt[i]) begin
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