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

typedef struct packed {
    logic [2:0] byte_off;
    logic [1:0] half_off;
    logic       word_off;
} DW_ACCESS;

/*
NOTE: The cache op tag doubles as priority value,
with max priority at lowest tag value! */
typedef enum logic[1:0] {
    FILL = 0,
    LOAD = 1,
    STOR = 2,
    NUM_OPS

    /* Ideally, we prioritize a (hit) load over a fill,
    but then we need to handle deferred fills.
    Deferred fills add lots of complexity, including
    a 'retry' path from the MSRH which should temporarily
    hold the data of a deferred fill. */
    // LOAD = 0,
    // MSHR = 1, // i.e. fill retry
    // FILL = 2,
    // STOR = 3,
    // NUM_OPS
} CACHE_OP_TAG;

typedef struct packed {
    logic   [NUM_SETS-1:0][ASSOC-1:0] vld;
    /* FIXME: dirty bit is currently unused */
    logic   [NUM_SETS-1:0][ASSOC-1:0] dirty;
    TAG     [NUM_SETS-1:0][ASSOC-1:0] tag;
    AGE     [NUM_SETS-1:0]            age;
} CACHE_HEADER;


typedef struct packed {
    CACHE_HEADER hdr;
    logic [NUM_SETS-1:0][ASSOC-1:0][$bits(MEM_BLOCK)-1:0]
        state;
} DBG_cache;
`endif