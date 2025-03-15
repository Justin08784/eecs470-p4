`include "sys_defs.svh"

module cdb #(parameter 
    N=`N
) (
    input clock,
    input reset,
    // input flush, //I don't think CDB cares about flush, since even when flushing we want CDB to do its job in order to flush
    input PHYS_REG_IDX [N-1:0] complete_tags,
    output logic [N-1:0] cdb_en,
    output PHYS_REG_IDX [N-1:0] cdb_broadcast
);

PHYS_REG_IDX [N-1:0] next_broadcast;
logic [N-1:0] next_cdb_en;

always_comb begin
    next_broadcast = complete_tags;
    next_cdb_en = '0;

    for (int i = 0; i < N; i++) begin
        if (complete_tags[i] != 0) begin
            next_cdb_en[i] = 1'b1;
        end
    end
end

always_ff @(posedge clock) begin
    if (reset) begin
        cdb_broadcast <= '0;
        cdb_en <= '0;
    end
    else begin
        cdb_broadcast <= next_broadcast;
        cdb_en <= next_cdb_en;
    end
end

endmodule