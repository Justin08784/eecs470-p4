`include "sys_defs.svh"
`include "dcache.svh"

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


module port_arbiter #(
    type ARB_BUS = logic [NUM_OPS-1:0][NUM_SETS-1:0]
) (
    input   logic [NUM_OPS-1:0] req,
    input   ARB_BUS rd_req_bus, wr_req_bus,

    output  logic [NUM_OPS-1:0] gnt,
    output  ARB_BUS rd_gnt_bus, wr_gnt_bus
);
    // `define PER_SET_ARB

`ifndef PER_SET_ARB
    // Per-cache arbitration [SIMPLIFICATION]
    // i.e. we accept only 1 of 2 requesting ops even if they have non-conflicting sets or port requests!
    always_comb begin
        gnt = '0;
        for (int op = 0; op < NUM_OPS; ++op) begin
            if (!req[op])
                continue;
            gnt[op] |= 1;
            break;
        end

        rd_gnt_bus = '0;
        wr_gnt_bus = '0;
        foreach (rd_gnt_bus[op]) begin
            if (!gnt[op])
                continue;
            rd_gnt_bus[op] |= rd_req_bus[op];
            wr_gnt_bus[op] |= wr_req_bus[op];
        end
    end
`endif

`ifdef PER_SET_ARB
    // Per-set arbitration
    logic   [NUM_OPS-1:0][NUM_SETS-1:0] gnt_bus;
    always_comb begin
        rd_gnt_bus = '0;
        wr_gnt_bus = '0;
        gnt        = '0;
        for (int s = 0; s < NUM_SETS; ++s) begin
            for (int op = 0; op < NUM_OPS; ++op) begin
                if (!rd_req_bus[op][s])
                    continue;
                rd_gnt_bus[op][s] = 1;
                break;
            end

            for (int op = 0; op < NUM_OPS; ++op) begin
                if (!wr_req_bus[op][s])
                    continue;
                wr_gnt_bus[op][s] = 1;
                break;
            end
        end

        foreach (gnt_bus[op, s])
            gnt_bus[op][s] = req[op]
                && (!rd_req_bus[op][s] || rd_gnt_bus[op][s])
                && (!wr_req_bus[op][s] || wr_gnt_bus[op][s]);
        foreach (gnt[op])
            gnt[op] = |gnt_bus[op];

        // gnt[FILL] = (~rd_req_bus[FILL] | rd_gnt_bus[FILL]) & wr_gnt_bus[FILL];
        // gnt[LOAD] = rd_gnt_bus[LOAD];
        // gnt[STOR] = rd_gnt_bus[STOR] & wr_gnt_bus[STOR];
    end
`endif

endmodule;


module dcache #(
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
    input MEM_SIZE      ld_size,   // only for load, store always write the ople block (might need to change)
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

    /*
    FIXME: MSHR needs to coalesce reads/loads, and partially
    coalesce writes/stores (maybe have a queue of allocated load/store
    per MSHR? This is important for stores, since they must be applied
    in-order...)
    */
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

    // Arbitration types
    logic [NUM_OPS-1:0][NUM_SETS-1:0]  rd_req_bus, wr_req_bus,
                                    rd_gnt_bus, wr_gnt_bus;
    logic [NUM_OPS-1:0] req, gnt;

    /* Load */
    logic   ld_hit;
    WAY     ld_way;
    SID     ld_sid;
    TAG     ld_tag;
    always_comb begin
        ld_tag = get_tag(ld_addr);
        ld_sid = get_sid(ld_addr);
        ld_hit = 0;
        ld_way = '0;
        for (int w = 0; w < ASSOC; ++w) begin
            if (!(cache_hdr.vld[ld_sid][w]
                && ld_tag == cache_hdr.tag[ld_sid][w]))
                continue;
            ld_way = w;
            ld_hit = 1;
        end

        rd_req_bus[LOAD] = '0;
        wr_req_bus[LOAD] = '0;
        rd_req_bus[LOAD][ld_sid] = ld_en && ld_hit;
    end

    /* Store */
    logic   st_hit;
    WAY     st_way;
    SID     st_sid;
    TAG     st_tag;
    always_comb begin
        st_tag = get_tag(st_addr);
        st_sid = get_sid(st_addr);

        // Is block in cache?
        st_hit = 0;
        st_way = '0;
        for (int w = 0; w < ASSOC; ++w) begin
            if (!(cache_hdr.vld[st_sid][w]
                && st_tag == cache_hdr.tag[st_sid][w]))
                continue;
            st_way = w;
            st_hit = 1;
        end

        rd_req_bus[STOR] = '0;
        wr_req_bus[STOR] = '0;
        rd_req_bus[STOR][st_sid] = st_en && st_hit;
    end

    /* Fill */
    logic   fl_en;
    WAY     fl_way;
    SID     fl_sid;
    TAG     fl_tag;
    always_comb begin
        /* FIXME: But there is only 1 write port to memDP, so you 
        somehow need to arbitrate between STORE and incoming mem block.
        Give priority to the incoming mem block. */
        fl_en  = mem_in_data_tag != 0;
        fl_tag = get_tag(mshr[mem_in_data_tag].addr);
        fl_sid = get_sid(mshr[mem_in_data_tag].addr);
        // cache_hdr_n = cache_hdr;

        rd_req_bus[FILL] = '0;
        wr_req_bus[FILL] = '0;
        rd_req_bus[FILL][fl_sid] = fl_en;
        wr_req_bus[FILL][fl_sid] = fl_en;

        for (int w = 0; w < ASSOC; ++w) begin
            if (!victim_msk[fl_sid][w])
                continue;
            /* TODO: need to write back if dirty. This just overwrites i.e.
            assumes clean */
            cache_hdr_n.vld[fl_sid][w]     = 1;
            cache_hdr_n.dirty[fl_sid][w]   = 0;
            cache_hdr_n.tag[fl_sid][w]     = fl_tag;
            cache_hdr_n.age[fl_sid]        = '0;
        end
    end

    // Port arbiter: op gets to read and write in each set?
    port_arbiter arb (
        .req        (req),
        .rd_req_bus (rd_req_bus),
        .wr_req_bus (wr_req_bus),

        .gnt        (gnt),
        .rd_gnt_bus (rd_gnt_bus),
        .wr_gnt_bus (wr_gnt_bus)
    );
    always_comb begin
        ren = '0;
        wen = '0;
        foreach (rd_gnt_bus[op, s]) begin
            ren[s] |= rd_gnt_bus[op][s];
            wen[s] |= wr_gnt_bus[op][s];
        end

        rway = '0;
        foreach (rd_gnt_bus[op, s]) begin
            if (!rd_gnt_bus[op][s])
                continue;
            case (op)
                LOAD: begin
                    rway[s] = ld_way;
                    ld_dat  = rdat;
                end
                FILL: begin
                    // TODO: handle
                    rway[s] = fl_way;
                end
                STOR: begin
                    rway[s] = st_way;
                end
                default:;
            endcase
        end

        wway = '0;
        wdat = '0;
        foreach (wr_gnt_bus[op, s]) begin
            if (!wr_gnt_bus[op][s])
                continue;
            case (op)
                LOAD: begin
                    wway[s] = ld_way;
                    ld_dat  = rdat;
                end
                FILL: begin
                    // TODO: handle
                    wway[s] = fl_way;
                    wdat[s] = mem_in_data;
                end
                STOR: begin
                    wway[s] = st_way;
                    wdat[s] = st_dat;
                end
                default:;
            endcase
        end


        // foreach (ren[s]) begin
        //     r_op[s] = 
        //         (ld_req && (ld_sid == s)) ? LOAD :
        //         (fl_req && (fl_sid == s)) ? FILL :
        //         (st_req && (st_sid == s)) ? STOR : NUM_OPS;

        //     w_op[s] = 
        //         (fl_req && (fl_sid == s)) ? FILL :
        //         (st_req && (st_sid == s)) ? STOR : NUM_OPS;

        // end

    end

    /* Request to MEM */
    typedef struct packed {
        ADDR     addr; // delay addr and memsize for one cycle to keep track of info to store to mshr
        MEM_SIZE size; // (bc the transaction_tag comes back from memory in the next cycle after receving request)
    } MISS_PKT; // pre MSHR
    MISS_PKT miss, miss_n;


    /* FILL handling. Handle MEM tag */
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