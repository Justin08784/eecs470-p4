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
        for (int n = 0; n < uen_cnt; ++n) begin
            if (udst[n] == `ZERO_REG)
                continue;
            foreach (snaps[i])
                snaps[i][udst[n]] <= ut[n];
        end

        for (int n = 0; n < wen_cnt; ++n) begin
            for (int i = 0; i < BMASK_LEN; ++i) begin
                if (!wmsk[n][i])
                    continue;
                snaps[i] <= wdat[n];
            end
        end

    end
endmodule