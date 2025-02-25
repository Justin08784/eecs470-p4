`include "sys_defs.svh"

module complete_list #(parameter
    PHYS_REG_SZ_R10K = `PHYS_REG_SZ_R10K
) (
    input clock,
    input reset,
    input [$clog2(PHYS_REG_SZ_R10K)-1:0] cdb_tag1,
    input [$clog2(PHYS_REG_SZ_R10K)-1:0] cdb_tag2,
    input [$clog2(PHYS_REG_SZ_R10K)-1:0] rob_tag1,
    input [$clog2(PHYS_REG_SZ_R10K)-1:0] rob_tag2,
    output logic complete_bit1,
    output logic complete_bit2
);

    logic [`PHYS_REG_SZ_R10K - 1:0] complete_list;
    always_ff @(posedge clock) begin
        if (reset) begin
            complete_list <= 0;
        end else begin
            complete_list[cdb_tag1] = 1'b1;
            complete_list[cdb_tag2] = 1'b1;
        end
    end

    always_comb begin
        complete_bit1 = complete_list[rob_tag1];
        complete_bit2 = complete_list[rob_tag2];
    end


endmodule