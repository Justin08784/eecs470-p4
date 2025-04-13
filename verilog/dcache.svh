`include "sys_defs.svh"

`ifndef __DCACHE_SVH__ 
`define __DCACHE_SVH__ 

localparam ASSOC   = 4;
localparam MSHR_SZ = 16;
localparam NUM_CACHE_LINES  =  `DCACHE_LINES;
localparam NUM_SETS         = NUM_CACHE_LINES / ASSOC;
localparam SET_INDEX_BITS   = $clog2(NUM_SETS);
localparam OFFSET_BITS      = 3;
localparam TAG_BITS         = 16 - SET_INDEX_BITS - OFFSET_BITS;
typedef logic [SET_INDEX_BITS-1:0]  SID;
typedef logic [TAG_BITS-1:0]        TAG;
typedef logic [OFFSET_BITS-1:0]     OFF;
typedef logic [$clog2(ASSOC)-1:0]   WAY;
typedef logic [ASSOC-1:0][ASSOC-1:0]AGE;

function automatic TAG get_tag(input ADDR addr);
    return addr[15:16-TAG_BITS];
endfunction
function automatic SID get_sid(input ADDR addr);
    return addr[SET_INDEX_BITS+OFFSET_BITS-1 : OFFSET_BITS];
endfunction
function automatic OFF get_off(input ADDR addr);
    return addr[OFFSET_BITS-1:0];
endfunction

typedef enum logic[1:0] {
    LOAD = 0,
    FILL = 1,
    STOR = 2,
    NUM_OPS
    // MSHR // i.e. fill retry
} WHO;
`endif