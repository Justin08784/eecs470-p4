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
    parameter MSHR_SZ = 16
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
    input logic         ld_en,
    input ADDR          ld_addr,
    input MEM_SIZE      ld_size,   // only for load, store always write the whole block (might need to change)
    output logic        ld_vld,  // indicates cache hit
    output MEM_BLOCK    ld_dat,

    input logic         st_en,
    input ADDR          st_addr,
    input MEM_SIZE      st_size,
    output logic        st_vld,  // indicates cache hit
    input MEM_BLOCK     st_dat,

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

    typedef struct packed {
        logic       vld;
        ADDR        addr;
        MEM_BLOCK   mem_data; // FIXME: Is this needed?
        MEM_SIZE    mem_size;
        logic       ready;
    } MSHR_ENTRY;
    MSHR_ENTRY  [MSHR_SZ-1:0] mshr, mshr_n;

    struct packed {
        logic   [NUM_SETS-1:0][ASSOC-1:0] vld;
        /* FIXME: dirty bit is currently unused */
        logic   [NUM_SETS-1:0][ASSOC-1:0] dirty;
        TAG     [NUM_SETS-1:0][ASSOC-1:0] tag;
        AGE     [NUM_SETS-1:0]            age;
    } cache_hdr, cache_hdr_n;


    logic       [NUM_SETS-1:0]  ren,  wen;
    WAY         [NUM_SETS-1:0]  rway, wway;            
    MEM_BLOCK   [NUM_SETS-1:0]  rdat, wdat;
    logic       [NUM_SETS-1:0][ASSOC-1:0] free_gnt;
    generate
        for (genvar s = 0; s < NUM_SETS; ++s) begin : gen_sets
            memDP #(
                .WIDTH     ($bits(MEM_BLOCK)),
                .DEPTH     (ASSOC),
                /* TODO: change this 2 read ports with 1 dedicated for load,
                1 for store. */
                .READ_PORTS(1),
                .BYPASS_EN (0)
            ) set_i (
                .clock(clock),
                .reset(reset),
                .re   (ren [s]),
                .raddr(rway[s]),
                .rdata(rdat[s]),
                .we   (wen [s]),
                .waddr(wway[s]),
                .wdata(wdat[s])
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

    /* Load */
    logic   ld_hit;
    WAY     ld_way;
    always_comb begin
        TAG     cur_tag;
        SID     cur_sid;
        cur_tag = get_tag(ld_addr);
        cur_sid = get_sid(ld_addr);

        ld_hit = 0;
        ld_way = '0;
        for (int w = 0; w < ASSOC; ++w) begin
            if (!(cache_hdr.vld[cur_sid][w]
                && cur_tag == cache_hdr.tag[cur_sid][w]))
                continue;
            ld_way = w;
            ld_hit = 1;
        end

        ld_dat = rdat[cur_sid][ld_way];
        // ld_vld = ld_en && ld_hit;
    end


    /* Store */
    logic   st_hit;
    WAY     st_way;
    always_comb begin
        TAG     cur_tag;
        SID     cur_sid;
        cur_tag = get_tag(st_addr);
        cur_sid = get_sid(st_addr);

        // Is block in cache?
        st_hit = 0;
        st_way = '0;
        for (int w = 0; w < ASSOC; ++w) begin
            if (!(cache_hdr.vld[cur_sid][w]
                && cur_tag == cache_hdr.tag[cur_sid][w]))
                continue;
            st_way = w;
            st_hit = 1;
        end
        // st_vld = st_en && st_hit;
    end


    /* Request to MEM */
    typedef struct packed {
        ADDR     addr; // delay addr and memsize for one cycle to keep track of info to store to mshr
        MEM_SIZE size; // (bc the transaction_tag comes back from memory in the next cycle after receving request)
    } MISS_PKT; // pre MSHR
    MISS_PKT miss, miss_n;

    /* Eviction */
    logic   [NUM_SETS-1:0] any_free;
    logic   [NUM_SETS-1:0][ASSOC-1:0] victim_msk;
    logic   [NUM_SETS-1:0][ASSOC-1:0] lru;
    always_comb begin
        /* FIXME: Placeholder LRU. Currently
        is 'bully 0 way' policy. */
        foreach(lru[s, i])
            lru[s][i] = i == 0;

        foreach(any_free[s])
            any_free[s] = |free_gnt[s];

        foreach(victim_msk[s]) begin
            victim_msk = any_free
                ? free_gnt[s]
                : lru;
        end
    end

    /* Handle MEM tag */
    MEM_BLOCK wdat_incoming;
    always_comb begin
        mshr_n = mshr;
        miss_n = '0;
        mem_out_command = MEM_NONE;

        if (ld_en && !ld_hit) begin
            mem_out_command = MEM_LOAD;
            mem_out_addr = ld_addr;
            miss_n = '{
                addr : ld_addr,
                size : ld_size
            };
        end else if (st_en && !st_hit) begin
            mem_out_command = MEM_LOAD;
            mem_out_addr = st_addr;
            miss_n = '{
                addr : st_addr,
                size : st_size
            };
        end

        if (mem_in_transaction_tag != 0) begin
            mshr_n[mem_in_transaction_tag] = '{
                vld         : 1,
                addr        : miss.addr,
                mem_data    : '0,
                mem_size    : miss.size,
                ready       : 0
            };
        end

        /* FIXME: But there is only 1 write port to memDP, so you 
        somehow need to arbitrate between STORE and incoming mem block.
        Give priority to the incoming mem block. */
        wdat_incoming = '0;
        cache_hdr_n = cache_hdr;
        if (mem_in_data_tag != 0) begin
            TAG     cur_tag;
            SID     cur_sid;
            cur_tag = get_tag(mshr[mem_in_data_tag].addr);
            cur_sid = get_sid(mshr[mem_in_data_tag].addr);

            for (int w = 0; w < ASSOC; ++w) begin
                if (!victim_msk[cur_sid][w])
                    continue;
                /* TODO: need to write back if dirty. This just overwrites i.e.
                assumes clean */
                cache_hdr_n.vld[cur_sid][w]     = 1;
                cache_hdr_n.dirty[cur_sid][w]   = 0;
                cache_hdr_n.tag[cur_sid][w]     = cur_tag;
                cache_hdr_n.age[cur_sid]        = '0;
            end

            mshr_n[mem_in_data_tag] = '0;
        end
    end


    /* Decide who actually gets to use the write port to the memDP */
    always_comb begin

    end


    always_ff @(posedge clock) begin
        if (reset) begin
            cache_hdr   <= '0;
            mshr        <= '0;
            miss        <= '0;
        end else begin
            cache_hdr   <= cache_hdr_n;
            mshr        <= mshr_n;
            miss        <= miss_n;
        end
    end



endmodule;