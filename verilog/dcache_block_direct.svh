`ifndef __DCACHE_BLOCK_DIRECT_SVH__ 
`define __DCACHE_BLOCK_DIRECT_SVH__ 

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

    OP_FILL_EVICT       =1,
    OP_FILL_NO_EVICT    =2,

    OP_LOAD_HIT         =3,
    OP_LOAD_MISS        =4,

    OP_STOR_HIT         =5,
    OP_STOR_MISS        =6,

    NUM_CACHE_OPS       =7
} OP_TAG;

typedef enum logic [1:0] {
    S_IDLE=0,
    S_NTAG=1,
    S_WAIT=2,
    S_FILL=3
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
    logic   [NUM_SETS-1:0][ASSOC-1:0] vld;
    logic   [NUM_SETS-1:0][ASSOC-1:0] dirty;
    TAG     [NUM_SETS-1:0][ASSOC-1:0] tag;
    AGE     [NUM_SETS-1:0]            age;
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
    MEM_TAG         tag; //not currently in use
    MEM_BLOCK       dat;
    LD_QUERY_STATUS status;
    LDB             ldb; //not currently in use
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

/* NOTE: This is also used to generate .out, so cannot debug guard
it as is typical for dbg structs. */
typedef struct packed {
    // input from memory
    MEM_TAG       mem_in_transaction_tag;
    MEM_BLOCK     mem_in_data;
    MEM_TAG       mem_in_data_tag;

    MEM_COMMAND   mem_out_command;
    ADDR          mem_out_addr;
    MEM_BLOCK     mem_out_data;

    // Load (w/ load FU)
    ld2dcache ld_in;
    dcache2ld ld_out;

    // Store (w/ SQ)
    sq2dcache sq_in;
    dcache2sq sq_out;

    MSHR_ENTRY mshr;
    CACHE_HEADER hdr;
    logic [NUM_SETS-1:0][ASSOC-1:0][$bits(MEM_BLOCK)-1:0] memDP;
} DBG_dcache;

typedef struct packed {
    logic   hit;
    TAG     tag;
    WAY     way;
    SID     sid;
} CACHE_LOC;

function automatic CACHE_LOC cache_locate(
    input CACHE_HEADER hdr,
    input ADDR addr
);
    logic   hit;
    TAG     tag;
    WAY     way;
    SID     sid;
    tag = get_tag(addr);
    sid = get_sid(addr);

    way = 0;
    hit = 0;
    for (int w = 0; w < ASSOC; ++w) begin
        if (hdr.vld[sid][w] && (tag == hdr.tag[sid][w])) begin
            hit = 1;
            way = w;
            break;
        end
    end

    return '{
        hit : hit,
        tag : tag,
        way : way,
        sid : sid
    };
endfunction

typedef struct packed {
    logic       vdm; // valid, dirty, match
    MEM_BLOCK   blk;
} QUERY_CACHE_RES;

function automatic QUERY_CACHE_RES _query_cache(
    input CACHE_HEADER hdr,
    logic [NUM_SETS-1:0][ASSOC-1:0][$bits(MEM_BLOCK)-1:0] state,
    input int double_idx
);
    MEM_BLOCK   rv;
    CACHE_LOC   loc;
    ADDR        addr;
    logic       match;

    addr = 8 * double_idx;
    loc = cache_locate(hdr, addr);

    match = loc.hit;
    rv  = state[loc.sid][loc.way];

    return '{
        vdm : hdr.vld[loc.sid][loc.way] && match && hdr.dirty[loc.sid][loc.way],
        blk : rv
    };
endfunction


`ifdef DEBUG
function automatic string dbg_ld_status(input LD_QUERY_STATUS s);
    string rv;
    rv = "unknown ld query status";
    case (s)
        LD_SUCC: rv = "LD_SUCC";
        LD_FAIL: rv = "LD_FAIL";
    endcase
    return rv;
endfunction;

function automatic string dbg_st_status(input ST_QUERY_STATUS s);
    string rv;
    rv = "unknown st query status";
    case (s)
        ST_SUCC: rv = "ST_SUCC";
        ST_FAIL: rv = "ST_FAIL";
    endcase
    return rv;
endfunction;

function automatic string dbg_mshr_status(input MSHR_STATUS s);
    string rv;
    rv = "unknown mshr status";
    case (s)
        S_IDLE: rv = "S_IDLE";
        S_NTAG: rv = "S_NTAG";
        S_WAIT: rv = "S_WAIT";
        S_FILL: rv = "S_FILL";
    endcase
    return rv;
endfunction;
`endif

`endif