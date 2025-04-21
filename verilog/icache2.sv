`include "icache.svh"
import icache_svh::*;


module icache2 (
    input clock,
    input reset,
    input flush,

    // Read control
    input  ADDR      raddr, // PC_reg
    output MEM_BLOCK rdat,
    output logic     rvld,
    // Fetch control (for prefetching)
    input  ADDR      faddr,
    input  ADDR      fvld,

    // From memory
    input MEM_TAG       mem_in_txn_tag, // Should be zero unless there is a response
    input MEM_BLOCK     mem_in_data,
    input MEM_TAG       mem_in_data_tag,

    // To memory
    output MEM_COMMAND  mem_out_command,
    output ADDR         mem_out_addr
);
    CACHE_HEADER hdr;

    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("%b", hdr.vld);
        end
    end
endmodule

