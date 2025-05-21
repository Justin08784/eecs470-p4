`include "sys_defs.svh"

module general_snaps #(
    parameter int WIDTH=32
) (
    input   clock,

    // read
    input   BMASK rmsk,
    output  logic [WIDTH-1:0] rdat,

    // write line
    input   logic [`N-1:0] wen,
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
        for (int n = 0; n < `N; ++n) begin
            if (!wen[n])
                continue;
            for (int i = 0; i < BMASK_LEN; ++i) begin
                if (!wmsk[n][i])
                    continue;
                snaps[i] <= wdat[n];
            end
        end
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
    input   logic [`N-1:0] wen,
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
        for (int n = 0; n < `N; ++n) begin
            if (!wen[n])
                continue;
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
    input   rename2bman dis_in,
    output  bman2rename dis_out
);
    BMASK bmask_reg;
    
    BMASK [`N-1:0]  b1hot_n;
    BMASK [`N:0]    bmask_n, cum_b1hot_n;
    psel_gen #(
        .WIDTH  (BMASK_LEN),
        .REQS   (`N)
    ) sel_b1hot (
        .req    (~bmask_reg),
        .gnt_bus(b1hot_n)
    );

    always_comb begin
        cum_b1hot_n[0] = '0; 
        for (int n = 0; n < `N; ++n)
            cum_b1hot_n[n+1] = cum_b1hot_n[n] | b1hot_n[n];

        bmask_n[0] = bmask_reg & ~clmsk;
        for (int n = 0; n < `N+1; ++n)
            bmask_n[n] = bmask_n[0] | cum_b1hot_n[n];

        dis_out.b1hot_n = b1hot_n;
        dis_out.bmask_n = bmask_n;
        dis_out.snap_rdy_scnt = `N;
        for (int n = 0; n < `N; ++n) begin
            if (|b1hot_n[n])
                continue;
            dis_out.snap_rdy_scnt = n;
            break;
        end
    end

    BMASK [BMASK_LEN-1:0] dep_table;
        // dep_table[i][j] := branch w/ b1hot j is dependent on branch w/ b1hot i

    always_ff @(posedge clock) begin
        assert ($onehot0({reset,clmsk})) else $fatal("clmsk not one-hot");

        if (reset) begin
            bmask_reg <= '0;
            dep_table <= '0;

        end else if (flush) begin
            foreach (clmsk[i]) begin
                if (!clmsk[i])
                    continue;
                bmask_reg   <= bmask_reg & ~(clmsk | dep_table[i]);
                dep_table[i]<= '0;
            end

            for (int i = 0; i < BMASK_LEN; ++i)
                dep_table[i] <= dep_table[i] & ~clmsk;

        end else begin
            bmask_reg <= bmask_n[dis_in.snap_en_cnt];

            for (int i = 0; i < BMASK_LEN; ++i)
                dep_table[i] <= (dep_table[i] & ~clmsk) | cum_b1hot_n[dis_in.snap_en_cnt];

            foreach (b1hot_n[n, i]) begin
                if (!b1hot_n[n][i] || n >= dis_in.snap_en_cnt)
                    continue;
                dep_table[i] <= cum_b1hot_n[dis_in.snap_en_cnt] & ~cum_b1hot_n[n+1];
                    // "all younger branches" MINUS "branches older than or equal to i"
            end
        end
    end

        end
    end

endmodule