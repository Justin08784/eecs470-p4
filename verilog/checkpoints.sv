`include "sys_defs.svh"

module general_snaps #(
    parameter int WIDTH=32
) (
    input   clock,

    // read
    input   BMASK rmsk,
    output  logic [WIDTH-1:0] rdat,

    // write line
    input   logic [N-1:0] wen,
    input   BMASK [N-1:0] wmsk,
    input   logic [N-1:0][WIDTH-1:0] wdat
);
    logic [BMASK_LEN-1:0][WIDTH-1:0] snaps;

    always_comb begin
        rdat = '0;
        foreach (rmsk[i]) begin
            if (rmsk[i])
                rdat = snaps[i];
        end
    end

    always_ff @(posedge clock) begin
        for (int n = 0; n < N; ++n) begin
            for (int i = 0; i < BMASK_LEN; ++i) begin
                if (wen[n] & wmsk[n][i])
                    snaps[i] <= wdat[n];
            end
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
    
    logic [N-1:0]  b1hot_rdy_n;
    BMASK [N-1:0]  b1hot_n;
    BMASK [N:0]    bmask_n, cum_b1hot_n;
    psel_gen #(
        .WIDTH  (BMASK_LEN),
        .REQS   (N)
    ) sel_b1hot (
        .req    (~bmask_reg),
        .gnt_bus(b1hot_n)
    );

    generate
    assign cum_b1hot_n[0]   = '0; 
    assign bmask_n    [0]   = bmask_reg & ~clmsk;
    for (genvar n = 0; n < N; ++n) begin       
        assign cum_b1hot_n[n+1] = cum_b1hot_n[n] | b1hot_n[n];
        assign bmask_n    [n+1] = bmask_n[0] | cum_b1hot_n[n+1];
        assign b1hot_rdy_n[n]   = |b1hot_n[n];
    end
    endgenerate

    always_comb begin
        dis_out.b1hot_n = b1hot_n;
        dis_out.bmask_n = bmask_n;
        dis_out.snap_rdy_scnt = N;
        
        foreach (b1hot_rdy_n[rev]) begin
            if (!b1hot_rdy_n[rev])
                dis_out.snap_rdy_scnt = rev;
        end
    end

    BMASK [BMASK_LEN-1:0] dep_table;
        // dep_table[i][j] := branch w/ b1hot j is dependent on branch w/ b1hot i

    always_ff @(posedge clock) begin
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
                    // "all new dispatching branches" MINUS "branches older than or equal to i"
            end
        end
    end


`ifdef FORMAL
    always_ff @(posedge clock) begin
        if (!reset)
            assert ($onehot0(clmsk)) else $fatal("clmsk not one-hot");
    end
`endif


`ifdef DEBUG
    task print_bman;
        $display("  %3d | >> Branch manager >>", $time);
        // $display("r_in.btq_rdy_scnt: %d",   btq_in.btq_rdy_scnt);
        // $display("btq_in.btq_rdy_scnt: %d",   btq_in.btq_rdy_scnt);
        for (int i = 0; i < N+1; ++i) begin
            $display("bmask_n[%2d]: %b, b1hot_n: %b, cum_b1hot_n: %b",
                i,
                bmask_n[i],
                b1hot_n[i],
                cum_b1hot_n[i]
            );
        end
        $display("bmask_reg: %b", bmask_reg);

        $display("");
        for (int i = 0; i < BMASK_LEN; ++i) begin
            if (bmask_reg[i])
                $display("dep_table[%8b]: %8b", 1 << i, dep_table[i]);
            else
                $display("dep_table[%8b]:", 1 << i);
        end
        $display("  %3d | << Branch manager <<", $time);
    endtask
`endif

endmodule