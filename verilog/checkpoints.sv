`include "sys_defs.svh"

module general_snaps #(
    parameter int WIDTH=32
) (
    input   clock,

    // read
    input   BMASK rmsk,
    output  logic [WIDTH-1:0] rdat,

    // write line
    input   logic [$clog2(`N):0] wen_cnt,
    input   BMASK [`N-1:0] wmsk,
    input   logic [`N-1:0][WIDTH-1:0] wdat
);
    logic [BMASK_LEN-1:0][WIDTH-1:0] snaps;

    always_comb begin
        rdat = '0;
        foreach (rmsk[i]) begin
            if (!rmsk[i])
                continue;
            rdat = snaps[i];
            break;
        end
    end

    always_ff @(posedge clock) begin
        for (int n = 0; n < wen_cnt; ++n) begin
            for (int i = 0; i < BMASK_LEN; ++i) begin
                if (!wmsk[n][i])
                    continue;
                snaps[i] <= wdat[n];
            end
        end
    end
endmodule

module fl_snaps #(
    parameter int DEPTH = `ROB_SZ,
    type PTR = logic [$clog2(DEPTH)-1:0],
    type CNT = logic [$clog2(DEPTH):0]
) (
    input   clock,

    // read
    input   BMASK   rmsk,
    output  PTR     rdat,

    // retire updates
    input   logic   [$clog2(`N):0] uen_cnt,

    // write line
    input   logic   [$clog2(`N):0] wen_cnt,
    input   BMASK   [`N-1:0] wmsk,
    input   PTR     [`N-1:0] wdat
);
    PTR [BMASK_LEN-1:0] snaps, snaps_n;
    function automatic PTR incr(input PTR p, input int unsigned k);
        logic [$clog2(DEPTH):0] carry;
        carry = p + k;
        return (carry >= DEPTH) ? carry - DEPTH : carry[$bits(PTR)-1:0];
    endfunction

    always_comb begin
        rdat = '0;
        foreach (rmsk[i]) begin
            if (!rmsk[i])
                continue;
            rdat = snaps[i];
            break;
        end

        snaps_n = snaps;
        for (int n = 0; n < wen_cnt; ++n) begin
            for (int i = 0; i < BMASK_LEN; ++i) begin
                if (!wmsk[n][i])
                    continue;
                snaps_n[i] = wdat[n];
            end
        end

        foreach (snaps_n[i])
            snaps_n[i] = incr(snaps_n[i], uen_cnt);
    end

    always_ff @(posedge clock) begin
        snaps <= snaps_n;
    end
endmodule


module mt_snaps #(

) (
    input   clock,

    // read
    input   BMASK rmsk,
    output  PHYS_REG_IDX [`NUM_ARCH_REG-1:0] rdat,

    // retire updates
    input   logic       [$clog2(`N):0] uen_cnt,
    input   REG_IDX     [`N-1:0] udst,
    input   PHYS_REG_IDX[`N-1:0] ut,

    // write line
    input   logic [$clog2(`N):0] wen_cnt,
    input   BMASK [`N-1:0] wmsk,
    input   PHYS_REG_IDX [`N-1:0][`NUM_ARCH_REG-1:0] wdat
);
    PHYS_REG_IDX [BMASK_LEN-1:0][`NUM_ARCH_REG-1:0] snaps;

    always_comb begin
        rdat = '0;
        foreach (rmsk[i]) begin
            if (!rmsk[i])
                continue;
            rdat = snaps[i];
            break;
        end
    end

    always_ff @(posedge clock) begin
        for (int n = 0; n < wen_cnt; ++n) begin
            for (int i = 0; i < BMASK_LEN; ++i) begin
                if (!wmsk[n][i])
                    continue;
                snaps[i] <= wdat[n];
            end
        end

        // QUESTION: does this ensure retires are applied onto same-cycle new snapshots?
        for (int n = 0; n < uen_cnt; ++n) begin
            if (udst[n] == `ZERO_REG)
                continue;
            foreach (snaps[i])
                snaps[i][udst[n]] <= ut[n];
        end
    end
endmodule

module branch_manager (
    input   clock,
    input   reset,
    input   flush,
    input   BMASK clmsk,

    // alloc
    input   dispatch2bman dis_in,
    output  bman2dispatch dis_out,

    output  bman2snap_bus snap_out
);
    BMASK bmask_reg;
    
    BMASK [`N-1:0]  b1hot_n;
    BMASK [`N:0]    bmask_n;
    psel_gen #(
        .WIDTH  (BMASK_LEN),
        .REQS   (`N)
    ) sel_b1hot (
        .req    (~bmask_reg),
        .gnt_bus(b1hot_n)
    );

    generate
    assign bmask_n[0] = bmask_reg;
    assign dis_out.bmask_n[0] = bmask_n[0];
    for (genvar n = 0; n < `N; ++n) begin : gen_bnext
        assign dis_out.b1hot_n[n]       = b1hot_n[n];
        assign dis_out.bmask_n[n + 1]   = bmask_n[n] | b1hot_n[n];
    end
    endgenerate
    always_comb begin
        dis_out.rdy_scnt = `N;
        for (int n = 0; n < `N; ++n) begin
            if (|b1hot_n[n])
                continue;
            dis_out.rdy_scnt = n;
            break;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            bmask_reg <= '0;
        end else if (flush) begin
            bmask_reg <= bmask_reg & ~clmsk;
        end else begin
            bmask_reg <= bmask_n[dis_in.snap_en_cnt] & ~clmsk;
        end
    end

    assign snap_out = '{
        b1hot_n     : b1hot_n,
        // pass throughs
        snap_en_cnt : dis_in.snap_en_cnt,
        btq_tail    : dis_in.btq_tail,
        fl_tail     : dis_in.fl_tail,
        rob_tail    : dis_in.rob_tail
    };

endmodule