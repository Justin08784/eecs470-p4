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
    input  ld2dcache dcache_out,

    /* Early CDB arbitration */
    output logic cdb_req,
    output PHYS_REG_IDX ctag_ts,
    input  logic cdb_gnt,

    /* BACKEND */
    output CPL_CAND o_cands
);
    localparam LD_BAY_SZ = `LD_BAY_SZ;//4;
    typedef struct packed {
        logic           [LD_BAY_SZ-1:0]  vld;
        logic           [LD_BAY_SZ-1:0]  got; // got data?
        PHYS_REG_IDX    [LD_BAY_SZ-1:0]  t;
        ROB_IDX         [LD_BAY_SZ-1:0]  rob_idx;
        ADDR            [LD_BAY_SZ-1:0]  addr;
        MEM_SIZE        [LD_BAY_SZ-1:0]  mem_size;

        LSQ_IDX         [LD_BAY_SZ-1:0]  sq_idx;
        logic           [LD_BAY_SZ-1:0][3:0]  st_frwd_byte_mask;
        DATA            [LD_BAY_SZ-1:0]  dat;
        logic           [LD_BAY_SZ-1:0] rd_unsigned;
    } LOAD_BAYS;


    // FIXME: Is this right? 
    // FIXME: hardcoded

    LOAD_BAYS bays; // waiting bays
    logic [LD_BAY_SZ-1:0] fu2in_gnt;
    logic [LD_BAY_SZ-1:0] fu2out_gnt;
    always_comb begin
        i_rdy = |(~bays.vld);
        cdb_req = |(bays.vld & bays.got);

        ctag_ts = '0;
        foreach (fu2out_gnt[i]) begin
            if (!fu2out_gnt[i])
                continue;
            ctag_ts |= bays.t[i];
        end
    end


    generate
        psel_gen #(
            .WIDTH(LD_BAY_SZ),
            .REQS(1)
        ) arb_in (
            .req    (~bays.vld),
            .gnt    (fu2in_gnt)
        );

        psel_gen #(
            .WIDTH(LD_BAY_SZ),
            .REQS(1)
        ) arb_out (
            .req    (bays.vld & bays.got),
            .gnt    (fu2out_gnt)
        );
    endgenerate

    ADDR        tmp_addrs;
    MEM_SIZE    tmp_sizes;

    always_comb begin
        // load address computation
        tmp_addrs = i_regs.rs1 + i_regs.dat.opb;
        tmp_sizes = i_regs.dat.mem_size;

        lq_out.ld_ex_en     = i_vld;
        lq_out.ld_lq_idx    = i_regs.dat.lq_idx;
        lq_out.ld_addr      = tmp_addrs;
        lq_out.ld_mem_size  = tmp_sizes;
    end

    CPL_CAND [1:0] cands_shr;
    always_comb begin
        o_cands = cands_shr[1];
    end
    
    //for forwarding, declared here so that it can be used here
    logic [LD_BAY_SZ-1:0] next_got;

    //mem request logic
    logic [$clog2(`LD_BAY_SZ):0] curr_frwd, next_frwd;
    logic [$clog2(`LD_BAY_SZ):0] pending_frwd, next_pending_frwd;
    logic pending, next_pending;
    always_comb begin
        next_frwd = curr_frwd;

        // case (pending)
        //     0 : begin
        //         if (bays.vld[curr_frwd] && !(bays.got[curr_frwd] || next_got[curr_frwd]) && !(reset || flush)) begin
        //             // $display("ASKING_MEM");
        //             // mem_command = MEM_LOAD;
        //             mem_addr = bays.addr[curr_frwd];
        //         end

        //         if (dcache_accepted && (mem_command == MEM_LOAD)) begin
        //             // $display("MEM_ACCEPTED");
        //             next_pending = 1;
        //             next_pending_frwd = curr_frwd;
        //         end
        //         else begin
        //             next_pending = 0;
        //             next_pending_frwd = 0;

        //             for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
        //                 if ((!bays.vld[i]) || bays.got[i]) continue;

        //                 next_frwd = i;
        //                 break;
        //             end
        //         end
        //     end
        //     1 : begin
        //             if (dcache_data_valid) begin
        //                 // $display("DATA_RETURNED[%b]: %h", dcache_data_valid, dcache_data);
        //                 next_pending = 0;
        //                 next_pending_frwd = 0;
        //             end
        //             else begin
        //                 next_pending = pending;
        //                 next_pending_frwd = pending_frwd;
        //             end
        //     end

        //     default : begin
        //         next_pending = 0;
        //         next_pending_frwd = 0;
        //         next_frwd = 0;
        //     end 
        // endcase

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
        foreach (bays.vld[i]) begin
            if (!bays.vld[i] || bays.got[i]) continue;
            
            ld_sq_out.forward_req_en[i] = bays.vld[i];
            ld_sq_out.forward_addr[i] = bays.addr[i];
            ld_sq_out.forward_mem_size[i] = bays.mem_size[i];
            ld_sq_out.forward_sq_idx[i] = bays.sq_idx[i];
        end
    end

    //ST-LD forwarding parsing logic
    logic [LD_BAY_SZ-1:0][3:0] next_st_frwd_byte_mask;
    DATA_BLOCK [LD_BAY_SZ-1:0] next_dat;
    always_comb begin
        next_got = bays.got;
        next_st_frwd_byte_mask = '0;
        next_dat = bays.dat;
        for (int unsigned i = 0; i < LD_BAY_SZ; i++) begin
            if (bays.got[i])
                continue;

            // if (pending && dcache_data_valid && (i == pending_frwd)) begin

            //     next_dat[i] = (dcache_data.word_level[bays.addr[i][2]]) >> bays.addr[i][1:0];
            //     next_got[i] = 1;
            // end

            if (sq_in.forward_byte_en[i][0])
                next_dat[i].byte_level[0] = sq_in.forward_data[i].byte_level[0];
            if (sq_in.forward_byte_en[i][1])
                next_dat[i].byte_level[1] = sq_in.forward_data[i].byte_level[1];
            if (sq_in.forward_byte_en[i][2])
                next_dat[i].byte_level[2] = sq_in.forward_data[i].byte_level[2];
            if (sq_in.forward_byte_en[i][3])
                next_dat[i].byte_level[3] = sq_in.forward_data[i].byte_level[3];
            next_st_frwd_byte_mask[i] = bays.st_frwd_byte_mask[i] | sq_in.forward_byte_en[i];

            next_got[i] |= ($countones(next_st_frwd_byte_mask[i]) == (2**bays.mem_size[i]));

            if (next_got[i]) begin
                if (bays.rd_unsigned[i]) begin
                    if (bays.mem_size[i] == BYTE) begin
                        next_dat[i][31:8] = '0;
                    end else if (bays.mem_size[i] == HALF) begin
                        next_dat[i][31:16] = '0;
                    end
                end
                else begin
                    if (bays.mem_size[i] == BYTE) begin
                        next_dat[i][31:8] = {(24){next_dat[i][7]}};
                    end else if (bays.mem_size[i] == HALF) begin
                        next_dat[i][31:16] = {(16){next_dat[i][15]}};
                    end
                end
            end

                // $display("FORWARDING_OCCURING: %0d, mask: %4b, final_data: %0d, ones: %0d, size: %0d, next_got:%b", sq_in.forward_data[i], sq_in.forward_byte_en[i], next_dat[i],$countones(next_st_frwd_byte_mask),2**bays.mem_size[i],next_got[i]);
        end
    end

    always_ff @(posedge clock) begin

        if (reset || flush) begin
            bays <= '0;
            cands_shr <= '0;
        end else begin
            foreach (fu2in_gnt[i]) begin
                if (!(fu2in_gnt[i] && i_vld))
                    continue;

                bays.vld     [i] <= 1;
                bays.got     [i] <= 0;
                bays.t       [i] <= i_regs.dat.t;
                bays.rob_idx [i] <= i_regs.dat.rob_idx;
                bays.addr    [i] <= tmp_addrs;
                bays.mem_size[i] <= tmp_sizes;
                bays.dat     [i] <= '0;
                bays.sq_idx  [i] <= i_regs.dat.sq_idx;
                bays.st_frwd_byte_mask[i] <= '0;
                bays.rd_unsigned[i] <= i_regs.dat.rd_unsigned;
            end

            foreach (next_got[i]) begin
                bays.got[i] <= next_got[i];
                bays.dat[i] <= next_dat[i];
                bays.st_frwd_byte_mask[i] <= next_st_frwd_byte_mask[i];
            end

            foreach (fu2out_gnt[i]) begin
                if (!(fu2out_gnt[i] && cdb_gnt))
                    continue;
                bays.vld     [i] <= 0;
                bays.got     [i] <= 0;
                bays.t       [i] <= '0;
                bays.rob_idx [i] <= '0;
                bays.addr    [i] <= '0;
                bays.mem_size[i] <= '0;
                bays.dat     [i] <= '0;
                bays.sq_idx  [i] <= '0;
                bays.st_frwd_byte_mask[i] <= '0;

                cands_shr[0] <= CPL_CAND'{
                    t       : bays.t[i],
                    rob_idx : bays.rob_idx[i],
                    data    : bays.dat[i]
                }; 
            end

            cands_shr[1] <= cands_shr[0];
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