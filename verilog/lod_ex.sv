`include "sys_defs.svh"
`include "execute.svh"
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
        MEM_BLOCK       raw;

        // readiness
        LSQ_IDX         sq_idx;
        logic [3:0]     need_byte_mask;
    } LOAD_BAY_ENTRY;

    typedef struct packed {
        logic           vld;

        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;

        // byte access information
        logic           rd_unsigned;
        MEM_SIZE        mem_size;

        DATA            dat;
    } LOAD_BUF_ENTRY;


    LOAD_BAY_ENTRY [BAY_SZ-1:0] bay, bay_n;
    LOAD_BUF_ENTRY [BUF_SZ-1:0] lbuf, lbuf_n;

    logic [BAY_SZ-1:0] bay_vld;
    logic [BAY_SZ-1:0] bay_need;

    logic [BUF_SZ-1:0] lbuf_vld;
    always_comb begin
        foreach (bay[i]) begin
            bay_vld[i]  = bay[i].vld;
            bay_need[i] = |(bay[i].need_byte_mask);
        end

        foreach (lbuf[i]) begin
            lbuf_vld[i] = lbuf[i].vld;
        end
    end


    logic [BAY_SZ-1:0] in2bay_gnt;
    logic [BUF_SZ-1:0] lbuf2cdb_gnt;
    generate
        psel_gen #(
            .WIDTH(BAY_SZ),
            .REQS(1)
        ) arb_in (
            .req    (~bay_vld),
            .gnt    (in2bay_gnt)
        );

        psel_gen #(
            .WIDTH  (BUF_SZ),
            .REQS   (1)
        ) arb_out (
            .req    (lbuf_vld),
            .gnt    (lbuf2cdb_gnt)
        );
    endgenerate



    always_comb begin
        i_rdy   = |in2bay_gnt;
        cdb_req = |lbuf_vld;

        ctag_ts = '0;
        foreach (lbuf2cdb_gnt[i]) begin
            if (!lbuf2cdb_gnt[i])
                continue;
            ctag_ts |= lbuf[i].t;
        end
    end

    logic [$clog2(BAY_SZ)-1:0]
        prv_qry,
        nex_qry,
        qry;

    logic [BAY_SZ-1:0] nex_qry_req, nex_qry_gnt;
    always_comb begin
        foreach (nex_qry_req[i])
            nex_qry_req = bay_vld[i] && bay_need[i];
    
        nex_qry = 0;
        foreach (nex_qry_gnt[i]) begin
            if (!nex_qry_gnt[i])
                continue;
            nex_qry |= i; // should be 1-hot
        end

        qry = nex_qry_req[prv_qry]
            ? prv_qry
            : nex_qry;
    end

    psel_gen #(
        .WIDTH  (BAY_SZ),
        .REQS   (1)
    ) qry_sel (
        .req    (nex_qry_req),
        .gnt    (nex_qry_gnt)
    );

    ADDR        in_addr;
    MEM_SIZE    in_size;
    always_comb begin
        // load address computation
        in_addr = i_regs.rs1 + i_regs.dat.opb;
        in_size = i_regs.dat.mem_size;

        lq_out = '{
            ld_ex_en     : i_vld,
            ld_lq_idx    : i_regs.dat.lq_idx,
            ld_addr      : in_addr,
            ld_mem_size  : in_size
        };
    end


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