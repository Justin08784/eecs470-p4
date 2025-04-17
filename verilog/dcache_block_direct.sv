`include "sys_defs.svh"
`include "dcache_block_direct.svh"


module dcache_block (
    input logic clock,
    input logic reset,

    // input from memory
    input  MEM_TAG       Dmem2Dcache_transaction_tag,
    input  MEM_BLOCK     Dmem2Dcache_data,
    input  MEM_TAG       Dmem2Dcache_data_tag,

    // input from lsq
    input logic          Dcache_valid_in, 
    // load (executing) store (retired)
    input MEM_COMMAND    proc2Dcache_command, // ✅ Bradley: only one command to dcache, so the load will see the effect of store
    input ADDR           proc2Dcache_addr,
    input MEM_SIZE       proc2Dcache_size,
    input MEM_BLOCK      proc2Dcache_wdata,

    // output to lsq
    output logic         req_accepted,
    output logic         Dcache_valid_out, // load cache hit
    output MEM_BLOCK     Dcache_data_out,
    // output info for load instruction that has the cache miss

    // output to memory 
    output MEM_COMMAND   Dcache2Dmem_command, // ✅ Bradley: IF Dcache and SQ have conflict on memory LET LOAD GO FIRST!!!!!
    output ADDR          Dcache2Dmem_addr,
    output MEM_BLOCK     Dcache2Dmem_wdata,

    output logic         mem_in_use,
    output logic         dcache_ready
);
    struct packed {
        logic   [NUM_CACHE_LINES-1:0] vld;
        logic   [NUM_CACHE_LINES-1:0] dirty;
        TAG     [NUM_CACHE_LINES-1:0] tag;
        logic   [$clog2(NUM_CACHE_LINES)-1:0] victim;
    } hdr, hdr_n;

    logic   ren,  wen;
    logic [$clog2(NUM_CACHE_LINES)-1:0]
            rway, wway;
    MEM_BLOCK rdat, wdat;
    logic [NUM_CACHE_LINES-1:0] free_gnt;
    memDP #(
        .WIDTH     ($bits(MEM_BLOCK)),
        .DEPTH     (NUM_CACHE_LINES),
        .READ_PORTS(1),
        .BYPASS_EN (0)
    ) state (
        .clock(clock),
        .reset(reset),
        .re   (ren ),
        .raddr(rway),
        .rdata(rdat),
        .we   (wen ),
        .waddr(wway),
        .wdata(wdat)
    );

    psel_gen #(
        .WIDTH(NUM_CACHE_LINES),
        .REQS(1)
    ) free_way (
        .req (~hdr.vld),
        .gnt (free_gnt)
    );

endmodule