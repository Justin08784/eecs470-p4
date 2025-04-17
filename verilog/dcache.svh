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

typedef enum logic [3:0] {
    OP_NONE             =0,

    OP_FILL_EVICT_BOTH  =1,
    OP_FILL_EVICT_MAIN  =2,
    OP_FILL_NO_EVICT    =3,

    OP_LOAD_MHIT        =4,
    OP_LOAD_VHIT_PULL   =5,
    OP_LOAD_VHIT_SWAP   =6,
    OP_LOAD_MISS        =7,

    OP_STOR_MHIT        =8,
    OP_STOR_VHIT_PULL   =9,
    OP_STOR_VHIT_SWAP   =10,
    OP_STOR_MISS        =11,

    NUM_CACHE_OPS       =12
} OP_TAG;

localparam int NUM_RES = 6;
typedef enum logic [$clog2(NUM_RES)-1:0] {
    RES_MEM   = 5,  // external memory cmd port
    RES_MSHR  = 4,  // MSHR allocator
    RES_VW    = 3,  // victim cache write port
    RES_VR    = 2,  // victim cache read  port
    RES_MW    = 1,  // main datapath write port
    RES_MR    = 0   // main datapath read  port
} RES_IDX;

typedef logic [NUM_RES-1:0] RES_MASK;
localparam RES_MASK
    M_MEM   = 6'b1_00000,
    M_MSHR  = 6'b0_10000,
    M_VW    = 6'b0_01000,
    M_VR    = 6'b0_00100,
    M_MW    = 6'b0_00010,
    M_MR    = 6'b0_00001;


typedef struct packed {
    OP_TAG op;

    struct packed {
        struct packed {
            logic   req;
            SID     sid;
            WAY     way;
        } r, w;
    } main;

    struct packed {
        struct packed {
            logic   req;
        } r, w;
    } vcache;

    struct packed {
        logic   allc_req;
    } mshr;

    struct packed {
        logic   talk_req; // want to talk to MEM
    } mem_out;

} OP_REQ;

typedef struct packed {
    struct packed {
        struct packed {
            logic   gnt;
        } r, w;
    } main;

    struct packed {
        struct packed {
            logic   gnt;
        } r, w;
    } vcache;

    struct packed {
        logic   allc_gnt;
    } mshr;

    struct packed {
        logic   talk_gnt; // want to talk to MEM
    } mem_out;

} OP_GNT;

typedef enum logic [1:0] {
    S_IDLE,
    S_NTAG,
    S_WAIT,
    S_FILL
} MSHR_STATUS;

typedef struct packed {
    MSHR_STATUS status;
    logic       wr_mem;
    ADDR        addr;
    MEM_BLOCK   mem_data;
    MEM_SIZE    mem_size;
} MSHR_ENTRY;

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