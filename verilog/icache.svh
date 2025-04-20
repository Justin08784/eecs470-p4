`ifndef ICACHE_SVH

package icache_svh;
    `include "sys_defs.svh"

    typedef logic [12-`ICACHE_LINE_BITS:0] WAY;
    typedef logic [`ICACHE_LINE_BITS -1:0] TAG;

    localparam NUM_CACHE_LINES  = `ICACHE_LINES;
    localparam OFFSET_BITS      = 3;
    localparam WAY_BITS         = $clog2(NUM_CACHE_LINES);
    localparam TAG_BITS         = 16 - WAY_BITS - OFFSET_BITS;

    typedef enum logic [1:0] {
        S_IDLE,
        S_NTAG,
        S_WAIT,
        S_FILL
    } MSHR_STATUS;

    typedef struct packed {
        MSHR_STATUS  status;
        TAG          tag;
        WAY          way;
    } MSHR;

    typedef struct packed {
        logic   [`ICACHE_LINES-1:0] vld;
        TAG     [`ICACHE_LINES-1:0] tag;
    } HEADER;
endpackage

`endif