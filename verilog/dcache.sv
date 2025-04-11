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

    input logic                     wen,
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
    localparam SET_INDEX_BITS   = $clog2(NUM_SETS);
    localparam OFFSET_BITS      = 3;
    localparam TAG_BITS         = 16 - SET_INDEX_BITS - OFFSET_BITS;
    typedef logic [SET_INDEX_BITS-1:0]  SID;
    typedef logic [TAG_BITS-1:0]        TAG;
    typedef logic [OFFSET_BITS-1:0]     OFF;
    typedef logic [$clog2(ASSOC)-1:0]   WAY;

    function automatic TAG get_tag(input ADDR addr);
        return [15:16-TAG_WIDTH];
    endfunction
    function automatic SID get_sid(input ADDR addr);
        return [SET_INDEX_BITS+OFFSET_BITS-1 : OFFSET_BITS];
    endfunction
    function automatic OFF get_off(input ADDR addr);
        return addr[OFFSET_BITS-1:0];
    endfunction

    struct packed {
        logic   [NUM_SETS-1:0][ASSOC-1:0] vld;
        TAG     [NUM_SETS-1:0][ASSOC-1:0] tag;
    } cache_hdr;

    TAG     [NUM_READ-1:0] cur_tag;
    SID     [NUM_READ-1:0] cur_sid;
    logic   [NUM_READ-1:0] rhit;
    WAY     [NUM_READ-1:0] rway;
    logic   [NUM_READ-1:0] rhit;

    generate
        for (genvar s = 0; s < NUM_SETS; ++s) begin : gen_sets
            memDP #(
                .WIDTH     ($bits(MEM_BLOCK)),
                .DEPTH     (ASSOC),
                .READ_PORTS(NUM_READ),
                .BYPASS_EN (0)
            ) set_i (
                .clock(clock),
                .reset(reset),
                .re   (ren),
                .raddr(rway[i]),
                .rdata(rdat),
                .we   (),
                .waddr(),
                .wdata()
            );
        end
    endgenerate

    always_comb begin
        foreach (ren[i]) begin
            cur_tag[i] = get_tag(raddr[i]);
            cur_sid[i] = get_sid(raddr[i]);
        end

        rway = '0;
        foreach (cache_hdr.tag[i, j]) begin
            if (cur_tag[i] != cache_hdr.tag[cur_sid[i]][j])
                continue;
            rway[i] |= j;
        end

        rhit = '0;
        rdat = '0;
        foreach (rhit[i]) begin
            rhit[i] = |rway[i];
            rdat[i] = 
        end
    end


    always_ff @(posedge clock) begin
        if (reset) begin
            cache_hdr <= '0;
        end else begin
        end
    end



endmodule;