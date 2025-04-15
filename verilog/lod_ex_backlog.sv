psel_gen #(
    .WIDTH(BAY_SZ),
    .REQS(1)
) arb_out (
    .req    (bays.vld[f] & bays.got[f]),
    .gnt    (fu2out_gnt[f])
);

typedef struct packed {
    logic           [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  vld;
    logic           [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  got; // got data?
    PHYS_REG_IDX    [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  t;
    ROB_IDX         [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  rob_idx;
    ADDR            [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  addr;
    MEM_SIZE        [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  mem_size;

    LSQ_IDX         [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  sq_idx;
    logic           [3:0]             [LD_BAY_SZ-1:0]  st_frwd_byte_mask;
    DATA            [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0]  dat;
} LOAD_BAYS;
logic [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] rvld;
DATA  [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] rdat;


// FIXME: Is this right? 
// FIXME: hardcoded


fake_dcache #(
    .NUM_RPORTS(`NUM_FU_LOAD * LD_BAY_SZ)
) cache0 (
    .clock,
    .reset

    // .ren    (bays.vld & ~bays.got),
    // .raddr  (bays.addr),
    // .rsize  (bays.mem_size),
    // .rdat   (rdat),
    // .rvld   (rvld)
);

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
        /* FIXME: What about rd_unsigned? We are not using this
        in lq???? */ //ANSWER: This needs to be used in the load FU

    end

    o_cands = '0;
    foreach (fu2out_gnt[f, i]) begin
        if (!(fu2out_gnt[f][i] && o_rdy[f]))
            continue;
        o_cands[f] |= CPL_CAND'{
            t       : bays.t[f][i],
            rob_idx : bays.rob_idx[f][i],
            data    : bays.dat[f][i],
            btq_idx : '0,
            take    : '0,
            is_brch : '0
        };
    end
end

//ST-LD forwarding request logic
always_comb begin
    ld_sq_out = '0;
    foreach (bays.vld[f,i]) begin
        if (!bays.vld[f][i]) continue;

        ld_sq_out.forward_req_en[i] = bays.vld[f][i];
        ld_sq_out.forward_addr[i] = bays.addr[f][i];
        ld_sq_out.forward_mem_size[i] = bays.mem_size[f][i];
        ld_sq_out.forward_sq_idx[i] = bays.sq_idx[f][i];
    end
end

//ST-LD forwarding parsing logic
logic [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] next_got;
logic [3:0]             [LD_BAY_SZ-1:0] got_byte_mask;
DATA_BLOCK  [`NUM_FU_LOAD-1:0][LD_BAY_SZ-1:0] next_dat;
always_comb begin
    next_got = bays.got;
    got_byte_mask = '0;
    next_dat = bays.dat;
    foreach (rvld[f, i]) begin
        if (bays.got[f][i])
            continue;
        if (!sq_in.forward_en[i])
            continue;

        // if (rvld[f][i]) begin
        //     next_got[f][i] = 1;
        //     next_dat[f][i] = rdat[f][i];
        // end

        if (sq_in.forward_byte_en[i][0])
            next_dat[f][i].byte_level[0] = sq_in.forward_data[i].byte_level[0];
        if (sq_in.forward_byte_en[i][1])
            next_dat[f][i].byte_level[1] = sq_in.forward_data[i].byte_level[1];
        if (sq_in.forward_byte_en[i][2])
            next_dat[f][i].byte_level[2] = sq_in.forward_data[i].byte_level[2];
        if (sq_in.forward_byte_en[i][3])
            next_dat[f][i].byte_level[3] = sq_in.forward_data[i].byte_level[3];
        got_byte_mask = bays.got_byte_mask[f][i] | sq_in.forward_byte_en[i];

        next_got[f][i] |= ($countones(got_byte_mask) == (2**bays.mem_size[f][i]));

            // $display("FORWARDING_OCCURING: %0d, mask: %4b, final_data: %0d, ones: %0d, size: %0d, next_got:%b", sq_in.forward_data[i], sq_in.forward_byte_en[i], next_dat[f][i],$countones(got_byte_mask),2**bays.mem_size[f][i],next_got[f][i]);
    end
end

always_ff @(posedge clock) begin

    if (reset || flush) begin
        bays <= '0;
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
            bays.got_byte_mask[f][i] <= '0;
        end

        foreach (next_got[f, i]) begin
            bays.got[f][i] <= next_got[f][i];
            bays.dat[f][i] <= next_dat[f][i];
            bays.got_byte_mask[f][i] <= got_byte_mask[f][i];
        end

        foreach (fu2out_gnt[f, i]) begin
            if (!(fu2out_gnt[f][i] && o_rdy[f]))
                continue;
            bays.vld     [f][i] <= 0;
            bays.got     [f][i] <= 0;
            bays.t       [f][i] <= '0;
            bays.rob_idx [f][i] <= '0;
            bays.addr    [f][i] <= '0;
            bays.mem_size[f][i] <= '0;
            bays.dat     [f][i] <= '0;
            bays.sq_idx  [f][i] <= '0;
            bays.got_byte_mask[f][i] <= '0;
        end
    end
end

`ifdef DEBUG
always_ff @(posedge clock) begin
    if (!reset) begin
        $display("  %3d | >> BAYS", $time);
        $display("i_rdy: %b, i_vld: %b, o_vld: %b, o_rdy: %b", i_rdy, i_vld, o_vld, o_rdy);
        $display("ocands: t: %2d, rob_idx: %2d, data: %x, btq_idx: %2d, take: %b, is_brch: %b",
            o_cands[0].t,
            o_cands[0].rob_idx,
            o_cands[0].data,
            o_cands[0].btq_idx,
            o_cands[0].take,
            o_cands[0].is_brch,
        );
        $display("ren: %b, rvld: %b", bays.vld & ~bays.got, rvld);
        foreach (fu2in_gnt[f, i]) begin
            $display("bays[%2d][%2d]: vld=%b, got=%b, t=%2d, rob_idx=%2d, addr=%x, mem_size=%2d, dat=%x",
                f,
                i,
                bays.vld    [f][i],
                bays.got    [f][i],
                bays.t      [f][i],
                bays.rob_idx[f][i],
                bays.addr   [f][i],
                bays.mem_size[f][i],
                bays.dat    [f][i]
            );
        end
        $display("  %3d | << BAYS", $time);
    end
end
`endif