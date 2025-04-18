`ifndef __DCACHE_BLOCK_DIRECT_SVH__ 
`define __DCACHE_BLOCK_DIRECT_SVH__ 

`include "sys_defs.svh"

localparam NUM_CACHE_LINES  =  `DCACHE_LINES;
localparam OFFSET_BITS      = 3;
localparam TAG_BITS         = 16 - OFFSET_BITS;
typedef logic [TAG_BITS-1:0]    TAG;
typedef logic [OFFSET_BITS-1:0] OFF;
typedef logic [$clog2(NUM_CACHE_LINES)-1:0] WAY;
// typedef logic [ASSOC-1:0][ASSOC-1:0]AGE;

function automatic TAG get_tag(input ADDR addr);
    return addr[15:16-TAG_BITS];
endfunction

typedef struct packed {
    logic [2:0] byte_off;
    logic [1:0] half_off;
    logic       word_off;
} DW_ACCESS;

typedef enum logic [3:0] {
    OP_NONE             =0,

    OP_FILL_EVICT       =1,
    OP_FILL_NO_EVICT    =2,

    OP_LOAD_HIT         =3,
    OP_LOAD_MISS        =4,

    OP_STOR_HIT         =5,
    OP_STOR_MISS        =6,

    NUM_CACHE_OPS       =7
} OP_TAG;

typedef enum logic [1:0] {
    S_IDLE,
    S_NTAG,
    S_WAIT,
    S_FILL
} MSHR_STATUS;

typedef struct packed {
    MSHR_STATUS status;
    logic       wr_mem;
    MEM_TAG     miss_tag;
    ADDR        addr;
    MEM_BLOCK   mem_data;
    MEM_SIZE    mem_size;
} MSHR_ENTRY;

typedef struct packed {
    logic   [NUM_CACHE_LINES-1:0] vld;
    logic   [NUM_CACHE_LINES-1:0] dirty;
    TAG     [NUM_CACHE_LINES-1:0] tag;
    logic   [$clog2(NUM_CACHE_LINES)-1:0] vict_way;
    // AGE     [NUM_CACHE_LINES-1:0] age;
} CACHE_HEADER;


typedef struct packed {
    CACHE_HEADER hdr;
    logic [NUM_CACHE_LINES-1:0][$bits(MEM_BLOCK)-1:0]
        state;
} DBG_cache;

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
    LD_SUCC,
    LD_FAIL
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