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
    parameter ASSOC   = 4,
    parameter MSHR_SZ = 32
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
    input logic ren,
    input ADDR  raddr,
    input MEM_SIZE  rsize,   // only for load, store always write the whole block (might need to change)
    output logic    rvld,  // indicates cache hit
    output MEM_BLOCK rdat,

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

    struct packed {
        logic   [NUM_SETS-1:0][ASSOC-1:0] vld;
        /* FIXME: dirty bit is currently unused */
        logic   [NUM_SETS-1:0][ASSOC-1:0] dirty;
        TAG     [NUM_SETS-1:0][ASSOC-1:0] tag;
        AGE     [NUM_SETS-1:0]            age;
    } cache_hdr;

    logic   rhit;
    WAY     rway;
    MEM_BLOCK [NUM_SETS-1:0]            tmp_rdat;
    logic     [NUM_SETS-1:0][ASSOC-1:0] free_gnt;

    generate
        for (genvar s = 0; s < NUM_SETS; ++s) begin : gen_sets
            memDP #(
                .WIDTH     ($bits(MEM_BLOCK)),
                .DEPTH     (ASSOC),
                .READ_PORTS(1),
                .BYPASS_EN (0)
            ) set_i (
                .clock(clock),
                .reset(reset),
                .re   (ren),
                .raddr(rway),
                .rdata(tmp_rdat[s]),
                .we   (wen),
                .waddr(),
                .wdata(wdat)
            );

            psel_gen #(
                .WIDTH(ASSOC),
                .REQS(1)
            ) free_way (
                .req (~cache_hdr.vld[s]),
                .gnt (free_gnt[s])
            );
        end
    endgenerate

    always_comb begin
        TAG     cur_tag;
        SID     cur_sid;
        cur_tag = get_tag(raddr);
        cur_sid = get_sid(raddr);

        rway = '0;
        for (int i = 0; i < ASSOC; ++i) begin
            if (cur_tag != cache_hdr.tag[cur_sid][i])
                continue;
            rway |= i;
            rhit |= 1;
        end

        rdat = tmp_rdat[cur_sid][rway];
    end


    logic   [ASSOC-1:0] wmsk;
    logic   whit;
    WAY     wway;
    logic   [NUM_SETS-1:0][ASSOC-1:0] lru;
    always_comb begin
        TAG     cur_tag;
        SID     cur_sid;
        cur_tag = get_tag(waddr);
        cur_sid = get_sid(waddr);

        // Is block in cache?
        wway = '0;
        for (int i = 0; i < ASSOC; ++i) begin
            if (cur_tag != cache_hdr.tag[cur_sid][i])
                continue;
            wway |= i;
            whit |= 1;
        end

        /* FIXME: Placeholder LRU. Currently
        is 'bully 0 way' policy. */
        foreach(lru[s, i])
            lru[s][i] = i == 0;

        wmsk = |free_gnt[cur_sid]
            ? free_gnt[cur_sid]
            : lru;

        wway = '0;
        foreach (wmsk[i]) begin
            if (!wmsk[i])
                continue;
            wway |= i;
        end
    end


    always_ff @(posedge clock) begin
        if (reset) begin
            cache_hdr <= '0;
        end else begin
        end
    end



endmodule;