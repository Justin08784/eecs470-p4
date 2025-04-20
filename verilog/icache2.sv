`include "icache.svh"

module icache2();
import icache_svh::*;
WAY esv;
endmodule


// typedef logic [12-`ICACHE_LINE_BITS:0] IC_WAY;
// typedef logic [`ICACHE_LINE_BITS -1:0] IC_TAG;

// localparam NUM_IC_LINES     = `ICACHE_LINES;
// localparam IC_OFFSET_BITS   = 3;
// localparam IC_WAY_BITS      = $clog2(NUM_CACHE_LINES);
// localparam IC_TAG_BITS      = 16 - WAY_BITS - OFFSET_BITS;

// typedef enum logic [1:0] {
//     IC_IDLE,
//     // S_NTAG,
//     IC_WAIT,
//     IC_FILL
// } IC_MSHR_STATUS;

// typedef struct packed {
//     IC_MSHR_STATUS  status;
//     // MEM_TAG         miss_tag; // dont need this; index into MSHR array will be our miss tag

//     IC_TAG          tag;
//     IC_WAY          way;
// } IC_MSHR;

// typedef struct packed {
//     logic   [`ICACHE_LINES-1:0] vld;
//     IC_TAG  [`ICACHE_LINES-1:0] tag;
// } IC_HEADER;


// module imoney (
//     `ifdef DEBUG
//     output DBG_imoney dbg,
//     `endif 
//     input clock,
//     input reset,
//     input flush,

//     // Read control
//     input  ADDR      raddr, // PC_reg
//     output MEM_BLOCK rdat,
//     output logic     rvld,
//     // Fetch control (for prefetching)
//     input  ADDR      faddr,
//     input  ADDR      fvld,

//     // From memory
//     input MEM_TAG       mem_in_txn_tag, // Should be zero unless there is a response
//     input MEM_BLOCK     mem_in_data,
//     input MEM_TAG       mem_in_data_tag,

//     // To memory
//     output MEM_COMMAND  mem_out_command,
//     output ADDR         mem_out_addr
// );
//     always_comb begin

//     end

// endmodule

