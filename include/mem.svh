`ifndef MEM_SVH
`define MEM_SVH

/* Memory config */
// Cache mode removes the byte-level interface from memory, so it always returns
// a double word. The original processor won't work with this defined. Your new
// processor will have to account for this effect on mem.
// Notably, you can no longer write data without first reading.
// TODO: uncomment this line once you've implemented your cache
`define CACHE_MODE

parameter int DCACHE_LINES = 32;

/* Constants */
typedef logic [31:0] ADDR;
typedef logic [15:0] BADDR;
typedef logic [14:0] HADDR;
typedef logic [13:0] WADDR;
typedef logic [12:0] DWADDR;

// Double word address (restricted to only used 16 LSB)
function automatic DWADDR addr2dw(input ADDR addr);
    return addr[15:3];
endfunction
function automatic ADDR dw2addr(input DWADDR addr);
    return {16'b0, addr, 3'b0};
endfunction

// Word address
function automatic WADDR addr2w(input ADDR addr);
    return addr[15:2];
endfunction
function automatic ADDR w2addr(input WADDR addr);
    return {16'b0, addr, 2'b0};
endfunction

// In-word byte offset
function automatic logic[1:0] iw_off(input ADDR addr);
    return addr[1:0];
endfunction

// In-double-word byte offset
function automatic logic[2:0] idw_off(input ADDR addr);
    return addr[2:0];
endfunction

// you are not allowed to change this definition for your final processor
// the project 3 processor has a massive boost in performance just from having no mem latency
// see if you can beat it's CPI in project 4 even with a 100ns latency!
//`define MEM_LATENCY_IN_CYCLES  0
`define MEM_LATENCY_IN_CYCLES (100.0/`CLOCK_PERIOD+0.49999)
// the 0.49999 is to force ceiling(100/period). The default behavior for
// float to integer conversion is rounding to nearest

// memory tags represent a unique id for outstanding mem transactions
// 0 is a sentinel value and is not a valid tag
`define NUM_MEM_TAGS 15
typedef logic [3:0] MEM_TAG;

`define MEM_SIZE_IN_BYTES (64*1024)
`define MEM_64BIT_LINES   (`MEM_SIZE_IN_BYTES/8)

// A memory or cache block
typedef union packed {
    logic [7:0][7:0]  byte_level;
    logic [3:0][15:0] half_level;
    logic [1:0][31:0] word_level;
    logic      [63:0] dbbl_level;
} MEM_BLOCK;
typedef union packed {
    logic [3:0][7:0]  byte_level;
    logic [1:0][15:0] half_level;
    logic      [31:0] word_level;
} DATA_BLOCK;

typedef enum logic [1:0] {
    BYTE   = 2'h0,
    HALF   = 2'h1,
    WORD   = 2'h2,
    DOUBLE = 2'h3
} MEM_SIZE;

// Memory bus commands
typedef enum logic [1:0] {
    MEM_NONE = 2'h0,
    MEM_LOAD = 2'h1,
    MEM_STORE= 2'h2
} MEM_COMMAND;

`endif // MEM_SVH 