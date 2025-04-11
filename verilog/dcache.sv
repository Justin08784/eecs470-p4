// Get word address; restricting to only actually used 16 LSB.
 function automatic logic[13:0] waddr(input ADDR addr);
     return addr[15:2];
 endfunction
 // Double word address
 function automatic logic[12:0] dwaddr(input ADDR addr);
     return addr[15:3];
 endfunction
 
 // In-word byte offset
 function automatic logic[1:0] iw_off(input ADDR addr);
     return addr[1:0];
 endfunction
 
 // In-double-word byte offset
 function automatic logic[2:0] idw_off(input ADDR addr);
     return addr[2:0];
 endfunction


module dcache #(
    parameter ASSOC     = 4,
    parameter MSHR_SZ = 16,
    parameter NUM_READ  = 2
) (
    input logic clock,
    input logic reset,

    // input from memory
    input  MEM_TAG       mem_in_transaction_tag,
    input  MEM_BLOCK     mem_in_data,
    input  MEM_TAG       mem_in_data_tag,

    output MEM_COMMAND   mem_out_command, // ✅ Bradley: IF Dcache and SQ have conflict on memory LET LOAD GO FIRST!!!!!
    output ADDR          mem_out_addr,


    // input from lsq
    input logic [NUM_READ-1:0]      ren,
    input ADDR [NUM_READ-1:0]       raddr,
    input MEM_SIZE [NUM_READ-1:0]   rsize,   // only for load, store always write the whole block (might need to change)
    output logic [NUM_READ-1:0]     rvld,  // indicates cache hit
    output MEM_BLOCK [NUM_READ-1:0] rdat,

    input ADDR                      waddr,
    input MEM_BLOCK                 wdat,

    output struct packed {
        ADDR        addr;
        MEM_BLOCK   data;
        MEM_SIZE    size;
    } miss_out // ????
);
    localparam NUM_CACHE_LINES  =  `DCACHE_LINES;
    localparam NUM_SETS         = NUM_CACHE_LINES / ASSOC;
    localparam OFFSET_BITS      = 3;
endmodule;