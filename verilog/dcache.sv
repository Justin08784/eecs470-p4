`include "sys_defs.svh"
`include "dcache.svh"


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


module replay_queue #(
    parameter int unsigned DEPTH=`RQ_SZ,       // num elements
    type RQ_STATE = struct packed {
        logic [$clog2(DEPTH)-1:0] head;
        logic [$clog2(DEPTH)-1:0] tail;
        RQ_ENTRY [DEPTH-1:0]      state;
        logic [$clog2(DEPTH):0]   used;
    },
    parameter int INSTANCE_ID=-1
) (
    input   clock, 
    input   reset,

    input   logic       wr_en,
    input   RQ_ENTRY    wr_data,

    input   logic       rd_en,
    output  RQ_ENTRY    rd_data,
    output  logic       prvw_vld,

    output  logic       empty,
    output  logic       full
);
    logic [$clog2(DEPTH)-1:0]       head;
    logic [$clog2(DEPTH)-1:0]       tail;
    RQ_ENTRY [DEPTH-1:0]            state;
    logic [$clog2(DEPTH):0]         used;

    always_comb begin
        empty    = used == 0;
        full     = used == DEPTH;
        prvw_vld = !empty;

        rd_data = prvw_vld
            ? state[head]
            : '0;
    end

    /* Uncomment this if you want to be anal and do some ridiculous micro-optimization. */
    // st_merge: Merge consecutive stores if they target the *SAME WORD* in the mem block
    // - consecutive stores -> no loads who need intermediate value -> can merge
    // logic last_vld;
    // logic [$clog2(DEPTH)-1:0] last_idx;
    // RQ_ENTRY last, last_n;
    // logic st_merge;
    // always_comb begin
    //     last_vld = !empty;
    //     last_idx = tail
    //         ? tail - 1
    //         : DEPTH - 1;
    //     last = state[last_idx];

    //     last_n = last;
    //     st_merge = last_vld
    //         && (last.acc.word_off == wr_data.acc.word_off)
    //         && !last.is_load
    //         && !wr_data.is_load;
    //     case (wr_data.size)
    //         BYTE: last_n.payload.st_dat.byte_level[wr_data.acc.byte_off]
    //             = wr_data.payload.st_dat.byte_level[0];
    //         HALF: last_n.payload.st_dat.half_level[wr_data.acc.half_off]
    //             = wr_data.payload.st_dat.half_level[0];
    //         WORD: last_n.payload.st_dat = wr_data.payload;
    //         default:;
    //     endcase
    // end

    always_ff @(posedge clock) begin
        if (reset) begin
            used    <= '0;
            head    <= '0;
            tail    <= '0;
            state   <= '0;
        end else begin
            if (wr_en > DEPTH - used)
                $error("RQ overflow! instance: %d", INSTANCE_ID);
            if (rd_en > used)
                $error("RQ underflow! instance: %d", INSTANCE_ID);
            used    <= used + wr_en - rd_en;
            head    <= (head + rd_en) % DEPTH;
            tail    <= (tail + wr_en) % DEPTH;

            if (wr_en)
                state[tail] <= wr_data;
            /* needed for st_merge */
            // if (wr_en) begin
            //     if (st_merge)
            //         state[last_idx] <= last_n;
            //     else
            //         state[tail]     <= wr_data;
            // end
        end
    end
endmodule
    


module mshr;
endmodule


module dcache #(
) (
    `ifdef DEBUG
    output DBG_cache dbg,
    `endif
    input logic clock,
    input logic reset,

    // input from memory
    input  MEM_TAG       mem_in_transaction_tag,
    input  MEM_BLOCK     mem_in_data,
    input  MEM_TAG       mem_in_data_tag,

    output MEM_COMMAND   mem_out_command,
    output ADDR          mem_out_addr,
    output MEM_BLOCK     mem_out_data,

    // input from lsq
    input logic         ld_vld,
    input ADDR          ld_addr,
    input MEM_SIZE      ld_size,    // only for load, store always write the ople block (might need to change)
    // FIXME: this status needs to be a more complex enum type, I think
    output logic        ld_status,
    output DATA_BLOCK   ld_dat,

    input logic         st_vld,
    input ADDR          st_addr,
    input MEM_SIZE      st_size,
    // FIXME: this status needs to be a more complex enum type, I think
    output logic        st_status,
    input DATA_BLOCK    st_dat
);
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

    CACHE_HEADER cache_hdr, cache_hdr_n;
    MISS_PKT miss, miss_n;

    logic       [NUM_SETS-1:0]  ren,  wen;
    WAY         [NUM_SETS-1:0]  rway, wway;            
    MEM_BLOCK   [NUM_SETS-1:0]  rdat, wdat;
    logic       [NUM_SETS-1:0][ASSOC-1:0] free_gnt;
    logic       [NUM_SETS-1:0][ASSOC-1:0][$bits(MEM_BLOCK)-1:0] dbg_state;
    generate
        for (genvar s = 0; s < NUM_SETS; ++s) begin : gen_sets
            memDP #(
                .WIDTH     ($bits(MEM_BLOCK)),
                .DEPTH     (ASSOC),
                .READ_PORTS(1),
                .BYPASS_EN (0)
            ) set_i (
                `ifdef DEBUG
                .dbg(dbg_state[s]),
                `endif
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

    // Arbitration types
    logic [NUM_OPS-1:0] req, gnt;
    logic [NUM_OPS-1:0][NUM_SETS-1:0]
        rd_req_bus, wr_req_bus,
        rd_gnt_bus, wr_gnt_bus;

    /* Load */
    logic   ld_hit;
    WAY     ld_way;
    SID     ld_sid;
    TAG     ld_tag;
    // Load: index decode + port request
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

        req[LOAD] = ld_vld && ld_hit;
        rd_req_bus[LOAD] = '0;
        wr_req_bus[LOAD] = '0;
        rd_req_bus[LOAD][ld_sid] = 1;

        ld_status = gnt[LOAD];
    end

    // Load: byte maniplation
    DW_ACCESS ld_acc;
    always_comb begin
        ld_acc = '{
            byte_off : idw_byte(ld_addr),
            half_off : idw_half(ld_addr),
            word_off : idw_word(ld_addr)
        };

        ld_dat = '0;
        case (ld_size)
            BYTE  : ld_dat = rdat[ld_sid].byte_level[ld_acc.byte_off];
            HALF  : ld_dat = rdat[ld_sid].half_level[ld_acc.half_off];
            WORD  : ld_dat = rdat[ld_sid].word_level;
            // FIXME: Double-word does not exist in RISC-V, right?
            // DOUBLE: ld_dat = rdat[ld_sid];
            default:;
        endcase
    end

    /* Store */
    // Store: index decode + port request
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

        req[STOR] = st_vld && st_hit;
        rd_req_bus[STOR] = '0;
        wr_req_bus[STOR] = '0;
        rd_req_bus[STOR][st_sid] = 1;
        wr_req_bus[STOR][st_sid] = 1;

        st_status = gnt[STOR];
    end

    // Store: byte manipulation
    MEM_BLOCK st_prew_dat;
    MEM_BLOCK st_posw_dat;
    DW_ACCESS st_acc;
    always_comb begin
        st_prew_dat = rdat[st_sid];
        st_posw_dat = st_prew_dat;
        st_acc = '{
            byte_off : idw_byte(st_addr),
            half_off : idw_half(st_addr),
            word_off : idw_word(st_addr)
        };
        case (st_size)
            BYTE  : st_posw_dat.byte_level[st_acc.byte_off] = st_dat.byte_level[0]; // lb
            HALF  : st_posw_dat.half_level[st_acc.half_off] = st_dat.half_level[0]; // lh
            WORD  : st_posw_dat.word_level[st_acc.word_off] = st_dat.word_level; // lw
            // FIXME: Double-word does not exist in RISC-V, right?
            // DOUBLE: st_posw_dat = st_dat;
            default:;
        endcase
    end

    // Victim selection and eviction
    /* Eviction */
    logic   [NUM_SETS-1:0] evict; // alloc in set requires evict? i.e. !(any free way in set)
    logic   [NUM_SETS-1:0][ASSOC-1:0] alloc_msk; // way to alloc
    logic   [NUM_SETS-1:0][ASSOC-1:0] lru; // lru victim way
    always_comb begin
        /* FIXME: Placeholder LRU. Currently
        is 'bully 0 way' policy. */
        foreach(lru[s, w])
            lru[s][w] = w == 0;

        foreach(evict[s])
            evict[s] = !(|free_gnt[s]);

        foreach(alloc_msk[s]) begin
            alloc_msk[s] = evict[s]
                ? lru[s]
                : free_gnt[s];
        end
    end

    /* Fill */ // TODO: Fill is stubbed
    // Fill: index decode + port request
    logic   fl_vld;
    WAY     fl_way;
    SID     fl_sid;
    TAG     fl_tag;
    always_comb begin
        /* FIXME: But there is only 1 write port to memDP, so you 
        somehow need to arbitrate between STORE and incoming mem block.
        Give priority to the incoming mem block. */
        fl_vld = mem_in_data_tag != 0;
        fl_tag = get_tag(mshr[mem_in_data_tag].addr);
        fl_sid = get_sid(mshr[mem_in_data_tag].addr);
        fl_way = 0;
        for (int w = 0; w < ASSOC; ++w) begin
            if (!alloc_msk[fl_sid][w])
                continue;
            fl_way = w;
            break;
        end

        req[FILL] = fl_vld;
        rd_req_bus[FILL] = '0;
        wr_req_bus[FILL] = '0;
        rd_req_bus[FILL][fl_sid] = evict[fl_sid]; // read nec. only if evict
        wr_req_bus[FILL][fl_sid] = 1;
    end

    // Port arbiter: which op gets to read and write in each set?
    port_arbiter arb (
        .req        (req),
        .rd_req_bus (rd_req_bus),
        .wr_req_bus (wr_req_bus),

        .gnt        (gnt),
        .rd_gnt_bus (rd_gnt_bus),
        .wr_gnt_bus (wr_gnt_bus)
    );

    // Route granted ops to memDP
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
                LOAD: rway[s] = ld_way;
                FILL: rway[s] = fl_way;
                STOR: rway[s] = st_way;
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
                    // TODO: handle for victim cache
                    // wway[s] = ld_way;
                end
                FILL: begin
                    wway[s] = fl_way;
                    wdat[s] = mem_in_data;
                end
                STOR: begin
                    wway[s] = st_way;
                    wdat[s] = st_posw_dat;
                end
                default:;
            endcase
        end
    end


    // Mem tag arbiter: who gets to request mem_tag?
    always_comb begin
        mshr_n = mshr;
        miss_n = '0;
        mem_out_command = MEM_NONE;
        mem_out_data = '0;

        // TODO: add dirty eviction branch (via FILL or LOAD-to-victim-cache caused eviction)
        if (ld_vld && !ld_hit) begin
            mem_out_command = MEM_LOAD;
            mem_out_addr = dw_align(ld_addr);
            miss_n = '{
                addr : ld_addr,
                size : ld_size
            };
        end else if (st_vld && !st_hit) begin
            mem_out_command = MEM_LOAD;
            mem_out_addr = dw_align(st_addr);
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

    // Update header
    // TODO: this is also where we should do LRU update
    always_comb begin
        cache_hdr_n = cache_hdr;
        if (gnt[LOAD])
            cache_hdr_n.age[st_sid]             = '0;

        if (gnt[STOR]) begin
            cache_hdr_n.vld[st_sid][st_way]     = 1;
            cache_hdr_n.dirty[st_sid][st_way]   = 1;
            cache_hdr_n.tag[st_sid][st_way]     = st_tag;
            cache_hdr_n.age[st_sid]             = '0;
        end

        if (gnt[FILL]) begin
            cache_hdr_n.vld[fl_sid][fl_way]     = 1;
            cache_hdr_n.dirty[fl_sid][fl_way]   = 0;
            cache_hdr_n.tag[fl_sid][fl_way]     = fl_tag;
            cache_hdr_n.age[fl_sid]             = '0;
        end
    end

    assign dbg = '{
        hdr     : cache_hdr,
        state   : dbg_state
    };
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