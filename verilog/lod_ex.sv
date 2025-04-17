`include "sys_defs.svh"
`include "execute.svh"

module lod_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic    [`NUM_FU_LOAD-1:0]  i_rdy,
        // ready to accept from regs.o_dat.lod?
    input  logic    [`NUM_FU_LOAD-1:0]  i_vld,
        // insns to accept from regs.o_dat.lod
    input  LOD_REGS [`NUM_FU_LOAD-1:0]  i_regs,
        // insn metadata/operands
    
    input   sq2execute sq_in,
    // output  execute2sq sq_out,
    output  execute2lq lq_out,
    output  executeLD2sq ld_sq_out,

    input logic dcache_accepted,
    input logic dcache_data_valid,
    input MEM_BLOCK dcache_data,

    output MEM_COMMAND mem_command,
    output ADDR mem_addr,

    /* Early CDB arbitration */
    output logic [`NUM_FU_LOAD-1:0]     cdb_req,
    output PHYS_REG_IDX [`NUM_FU_LOAD-1:0] ctag_ts,
    input  logic [`NUM_FU_LOAD-1:0]     cdb_gnt,

    /* BACKEND */
    output CPL_CAND [`NUM_FU_LOAD-1:0]  o_cands
);
    localparam LD_BAY_SZ = `LD_BAY_SZ;//4;
    typedef struct packed {
        logic           [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  vld;
        logic           [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  got; // got data?
        PHYS_REG_IDX    [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  t;
        ROB_IDX         [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  rob_idx;
        ADDR            [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  addr;
        MEM_SIZE        [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  mem_size;

        LSQ_IDX         [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  sq_idx;
        logic           [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0][3:0]  st_frwd_byte_mask;
        DATA            [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  dat;
        logic           [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] rd_unsigned;
    } LOAD_BAYS;


    // FIXME: Is this right? 
    // FIXME: hardcoded

    LOAD_BAYS bays; // waiting bays
    logic     [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] fu2in_gnt;
    logic     [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] fu2out_gnt;
    always_comb begin
        for (int f = 0; f < `NUM_FU_LOAD; ++f) begin
            i_rdy[f] = |(~bays.vld[f]);
            cdb_req[f] = |(bays.vld[f] & bays.got[f]);
        end

        ctag_ts = '0;
        foreach (fu2out_gnt[f, i]) begin
            if (!fu2out_gnt[f][i])
                continue;
            ctag_ts[f] |= bays.t[f][i];
        end
    end


    generate
        for (genvar f = 0; f < `NUM_FU_LOAD; ++f) begin : gen_arb_in
            psel_gen #(
                .WIDTH(LD_BAY_SZ),
                .REQS(1)
            ) arb_in (
                .req    (~bays.vld[f]),
                .gnt    (fu2in_gnt[f])
            );
        end

        for (genvar f = 0; f < `NUM_FU_LOAD; ++f) begin : gen_arb_out
            psel_gen #(
                .WIDTH(LD_BAY_SZ),
                .REQS(1)
            ) arb_out (
                .req    (bays.vld[f] & bays.got[f]),
                .gnt    (fu2out_gnt[f])
            );
        end
    endgenerate

    ADDR        [`NUM_FU_LOAD-1:0] tmp_addrs;
    MEM_SIZE    [`NUM_FU_LOAD-1:0] tmp_sizes;

    always_comb begin
        foreach(i_vld[i]) begin
            // load address computation
            tmp_addrs[i] = i_regs[i].rs1 + i_regs[i].dat.opb;
            tmp_sizes[i] = i_regs[i].dat.mem_size;

            lq_out.ld_ex_en[i]      = i_vld[i];
            lq_out.ld_lq_idx[i]     = i_regs[i].dat.lq_idx;
            lq_out.ld_addr[i]       = tmp_addrs[i];
            lq_out.ld_mem_size[i]   = tmp_sizes[i];

        end
    end

    CPL_CAND [1:0][`NUM_FU_LOAD-1:0] cands_shr;
    always_comb begin
        foreach (cands_shr[f])
            o_cands[f] = cands_shr[1][f];
    end
    
    //for forwarding, declared here so that it can be used here
    logic [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] next_got;

    //mem request logic
    logic [$clog2(`LD_BAY_SZ):0] curr_frwd, next_frwd;
    logic [$clog2(`LD_BAY_SZ):0] pending_frwd, next_pending_frwd;
    logic pending, next_pending;
    always_comb begin
        mem_command = MEM_NONE;
        mem_addr = 0;
        next_frwd = curr_frwd;

        case (pending)
            0 : begin
                if (bays.vld[0][curr_frwd] && !(bays.got[0][curr_frwd] || next_got[0][curr_frwd]) && !(reset || flush)) begin
                    // $display("ASKING_MEM");
                    mem_command = MEM_LOAD;
                    mem_addr = bays.addr[0][curr_frwd];
                end

                if (dcache_accepted && (mem_command == MEM_LOAD)) begin
                    // $display("MEM_ACCEPTED");
                    next_pending = 1;
                    next_pending_frwd = curr_frwd;
                end
                else begin
                    next_pending = 0;
                    next_pending_frwd = 0;

                    for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
                        if ((!bays.vld[0][i]) || bays.got[0][i]) continue;

                        next_frwd = i;
                        break;
                    end
                end
            end
            1 : begin
                    if (dcache_data_valid) begin
                        // $display("DATA_RETURNED[%b]: %h", dcache_data_valid, dcache_data);
                        next_pending = 0;
                        next_pending_frwd = 0;
                    end
                    else begin
                        next_pending = pending;
                        next_pending_frwd = pending_frwd;
                    end
            end

            default : begin
                next_pending = 0;
                next_pending_frwd = 0;
                next_frwd = 0;
            end 
        endcase

    end

    always_ff @(posedge clock) begin
        // $display("PENDING_STATE: %b",pending);
        if (reset || flush) begin
            curr_frwd <= '0;
            pending <= '0;
            pending_frwd <= '0;
        end
        else begin
            curr_frwd <= next_frwd;
            pending <= next_pending;
            pending_frwd <= next_pending_frwd;
        end
    end

    //ST-LD forwarding request logic
    always_comb begin
        ld_sq_out = '0;
        foreach (bays.vld[f,i]) begin
            if (!bays.vld[f][i] || bays.got[f][i]) continue;
            
            ld_sq_out.forward_req_en[i] = bays.vld[f][i];
            ld_sq_out.forward_addr[i] = bays.addr[f][i];
            ld_sq_out.forward_mem_size[i] = bays.mem_size[f][i];
            ld_sq_out.forward_sq_idx[i] = bays.sq_idx[f][i];
        end
    end

    //ST-LD forwarding parsing logic
    logic [LD_BAY_SZ-1:0][3:0] next_st_frwd_byte_mask;
    DATA_BLOCK  [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] next_dat;
    always_comb begin
        next_got = bays.got;
        next_st_frwd_byte_mask = '0;
        next_dat = bays.dat;
        for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
            if (bays.got[0][i])
                continue;
            // if (!sq_in.forward_en[i])
            //     continue;
            if (pending && dcache_data_valid && (i == pending_frwd)) begin

                next_dat[0][i] = (dcache_data.word_level[bays.addr[0][i][2]]) >> bays.addr[0][i][1:0];
                next_got[0][i] = 1;
            end

            if (sq_in.forward_byte_en[i][0])
                next_dat[0][i].byte_level[0] = sq_in.forward_data[i].byte_level[0];
            if (sq_in.forward_byte_en[i][1])
                next_dat[0][i].byte_level[1] = sq_in.forward_data[i].byte_level[1];
            if (sq_in.forward_byte_en[i][2])
                next_dat[0][i].byte_level[2] = sq_in.forward_data[i].byte_level[2];
            if (sq_in.forward_byte_en[i][3])
                next_dat[0][i].byte_level[3] = sq_in.forward_data[i].byte_level[3];
            next_st_frwd_byte_mask[i] = bays.st_frwd_byte_mask[0][i] | sq_in.forward_byte_en[i];

            next_got[0][i] |= ($countones(next_st_frwd_byte_mask[i]) == (2**bays.mem_size[0][i]));

            if (next_got[0][i]) begin
                if (bays.rd_unsigned[0][i]) begin
                    if (bays.mem_size[0][i] == BYTE) begin
                        next_dat[0][i][31:8] = '0;
                    end else if (bays.mem_size[0][i] == HALF) begin
                        next_dat[0][i][31:16] = '0;
                    end
                end
                else begin
                    if (bays.mem_size[0][i] == BYTE) begin
                        next_dat[0][i][31:8] = {(24){next_dat[0][i][7]}};
                    end else if (bays.mem_size[0][i] == HALF) begin
                        next_dat[0][i][31:16] = {(16){next_dat[0][i][15]}};
                    end
                end
            end

                // $display("FORWARDING_OCCURING: %0d, mask: %4b, final_data: %0d, ones: %0d, size: %0d, next_got:%b", sq_in.forward_data[i], sq_in.forward_byte_en[i], next_dat[f][i],$countones(next_st_frwd_byte_mask),2**bays.mem_size[f][i],next_got[f][i]);
        end
    end

    always_ff @(posedge clock) begin

        if (reset || flush) begin
            bays <= '0;
            cands_shr <= '0;
        end else begin
            foreach (fu2in_gnt[f, i]) begin
                if (!(fu2in_gnt[f][i] && i_vld[f]))
                    continue;

                bays.vld     [f][i] <= 1;
                bays.got     [f][i] <= 0;
                bays.t       [f][i] <= i_regs[f].dat.t;
                bays.rob_idx [f][i] <= i_regs[f].dat.rob_idx;
                bays.addr    [f][i] <= tmp_addrs[f];
                bays.mem_size[f][i] <= tmp_sizes[f];
                bays.dat     [f][i] <= '0;
                bays.sq_idx  [f][i] <= i_regs[f].dat.sq_idx;
                bays.st_frwd_byte_mask[f][i] <= '0;
                bays.rd_unsigned[f][i] <= i_regs[f].dat.rd_unsigned;
            end

            foreach (next_got[f, i]) begin
                bays.got[f][i] <= next_got[f][i];
                bays.dat[f][i] <= next_dat[f][i];
                bays.st_frwd_byte_mask[f][i] <= next_st_frwd_byte_mask[i];
            end

            foreach (fu2out_gnt[f, i]) begin
                if (!(fu2out_gnt[f][i] && cdb_gnt[f]))
                    continue;
                bays.vld     [f][i] <= 0;
                bays.got     [f][i] <= 0;
                bays.t       [f][i] <= '0;
                bays.rob_idx [f][i] <= '0;
                bays.addr    [f][i] <= '0;
                bays.mem_size[f][i] <= '0;
                bays.dat     [f][i] <= '0;
                bays.sq_idx  [f][i] <= '0;
                bays.st_frwd_byte_mask[f][i] <= '0;

                cands_shr[0][f] <= CPL_CAND'{
                    t       : bays.t[f][i],
                    rob_idx : bays.rob_idx[f][i],
                    data    : bays.dat[f][i]
                }; 
            end

            for (int f = 0; f < `NUM_FU_LOAD; ++f)
                cands_shr[1][f] <= cands_shr[0][f];
        end
    end

    // `ifdef DEBUG
    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("  %3d | >> BAYS", $time);
    //         $display("MEM_LOAD: %b, %d, %0d, %d", pending, dcache_data_valid, pending_frwd, dcache_data);
    //         $display("FRWD_EN: %b, %b", sq_in.forward_en, sq_in.forward_byte_en);
    //         $display("i_rdy: %b, i_vld: %b ", i_rdy, i_vld);
    //         $display("ocands: t: %2d, rob_idx: %2d, data: %x",
    //             o_cands[0].t,
    //             o_cands[0].rob_idx,
    //             o_cands[0].data
    //         );
    //         $display("ren: %b", bays.vld & ~bays.got);
    //         foreach (fu2in_gnt[f, i]) begin
    //             $display("bays[%2d][%2d]: vld=%b, got=%b, t=%2d, rob_idx=%2d, addr=%x, mem_size=%2d, dat=%x",
    //                 f,
    //                 i,
    //                 bays.vld    [f][i],
    //                 bays.got    [f][i],
    //                 bays.t      [f][i],
    //                 bays.rob_idx[f][i],
    //                 bays.addr   [f][i],
    //                 bays.mem_size[f][i],
    //                 bays.dat    [f][i]
    //             );
    //         end
    //         $display("  %3d | << BAYS", $time);
    //     end
    // end
    // `endif

    /* TODO: CAND generation logic. Also, how do we know when
    a load result is ready without an lq2execute line? */
endmodule