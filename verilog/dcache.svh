`ifndef __DCACHE_SVH__ 
`define __DCACHE_SVH__ 

`include "sys_defs.svh"


localparam ASSOC   = 4; // i.e. NUM_WAYS
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

`define RQ_SZ 4
typedef struct packed {
    logic       is_load;        // store, if not load
    union packed {
        struct packed {
            LSQ_IDX         lq_idx; // only needed for loads (stores only request to dcache post retirement)
            PHYS_REG_IDX    dst;
            logic [$bits(DATA_BLOCK)-$bits(LSQ_IDX)-$bits(PHYS_REG_IDX)-1:0]
                _pad; // ...I'm sorry
        } ld;
        DATA_BLOCK  st_dat;
    } payload;
    /* ^^ access guarded by size */

    MEM_SIZE    size; // mem size: BYTE, HALF, WORD, DOUBLE-WORD
    DW_ACCESS   acc;
    // union packed {
    //     logic [2:0] byte_off;
    //     logic [2:0] half_off;   // actually: logic[1:0] (padded 1 bit)
    //     logic [2:0] word_off;   // actually: logic      (padded 2 bits)
    // } acc;
    /* ^^ access guarded by size
    (NOT to be confused with DW_ACCESS, which is a struct!) */
} RQ_ENTRY;

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

typedef struct packed {
    ADDR     addr; // delay addr and memsize for one cycle to keep track of info to store to mshr
    MEM_SIZE size; // (bc the transaction_tag comes back from memory in the next cycle after receving request)
} MISS_PKT; // pre MSHR


function automatic ADDR w_align(input ADDR addr);
    return {addr[31:2], 2'b00};
endfunction
// Double word address
function automatic ADDR dw_align(input ADDR addr);
    return {addr[31:3], 3'b000};
endfunction

function automatic logic idw_word(input ADDR addr);
    return addr[2];
endfunction
function automatic logic [1:0] idw_half(input ADDR addr);
    return addr[2:1];
endfunction
function automatic logic [2:0] idw_byte(input ADDR addr);
    return addr[2:0];
endfunction

// I/O types
typedef enum logic [1:0] {
    LD_HIT_READ,    // Block in dcache and could read. Proceed to CDB buffer.
    LD_HIT_WAIT,    // Block in dcache and could not read. Must retry.
    LD_MISS_YTAG,   // Block not in dcache and alloc'd/coalesced into MSHR. Proceed to load buffer.
    LD_MISS_NTAG    // Block not in dcache and could not alloc/coalesce. Must retry.
} LD_QUERY_STATUS;

typedef enum logic {
    /*
    1. Wrote to dcache, or
    2. Merged into an MSHR (alloc'd new one, or merged into existing one)
    Either way, not SQ's concern anymore.
    */
    ST_SUCC,
    ST_FAIL // inverse of above, must retry
} ST_QUERY_STATUS;

typedef struct packed {
    logic       en;
    MEM_TAG     tag;
    MEM_BLOCK   blk;
} LDB; // load data bus (wakeup insns in load bay/buffer)

typedef struct packed {
    logic   vld;
    ADDR    addr;
} ld2dcache;
typedef struct packed {
    MEM_TAG         tag;
    DATA_BLOCK      dat;
    LD_QUERY_STATUS status;
    LDB             ldb;
} dcache2ld;

typedef struct packed {
    logic       vld;
    ADDR        addr;
    MEM_SIZE    size;
    DATA_BLOCK  dat;
} sq2dcache;
typedef struct packed {
    ST_QUERY_STATUS status;
} dcache2sq;

`endif