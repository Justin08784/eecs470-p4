`include "sys_defs.svh"
`include "dcache.svh"

typedef struct packed {
    logic   hit;
    SID     sid;
    TAG     tag;
    WAY     way;
} CACHE_LOC;

function automatic CACHE_LOC cache_locate(
    input CACHE_HEADER hdr,
    input ADDR addr
);
    logic   hit;
    SID     sid;
    TAG     tag;
    WAY     way;
    tag = get_tag(addr);
    sid = get_sid(addr);
    hit = 0;
    way = '0;
    for (int w = 0; w < ASSOC; ++w) begin
        if (!(hdr.vld[sid][w] && tag == hdr.tag[sid][w]))
            continue;
        way = w;
        hit = 1;
    end
    return '{hit, sid, tag, way};
endfunction

function automatic DATA_BLOCK extract_load(
    input MEM_SIZE    size,
    input ADDR        addr,
    input MEM_BLOCK   raw
);
    DATA_BLOCK rv;
    DW_ACCESS acc;

    rv = '0;
    acc = '{
        byte_off : idw_byte(addr),
        half_off : idw_half(addr),
        word_off : idw_word(addr)
    };

    case (size)
        BYTE  : rv = raw.byte_level[acc.byte_off];
        HALF  : rv = raw.half_level[acc.half_off];
        WORD  : rv = raw.word_level[acc.word_off];
        default:;
    endcase
    return rv;
endfunction

function automatic MEM_BLOCK apply_store(
    input MEM_SIZE      size,
    input ADDR          addr,
    input DATA_BLOCK    wdat,
    input MEM_BLOCK     prew
);
    MEM_BLOCK posw;
    DW_ACCESS acc;
    acc = '{
        byte_off : idw_byte(addr),
        half_off : idw_half(addr),
        word_off : idw_word(addr)
    };

    posw = prew;
    case (size)
        BYTE  : posw.byte_level[acc.byte_off] = wdat.byte_level[0];
        HALF  : posw.half_level[acc.half_off] = wdat.half_level[0];
        WORD  : posw.word_level[acc.word_off] = wdat.word_level;
        default:;
    endcase

    return posw;
endfunction

module dcache_basic (
    input logic clock,
    input logic reset,

    // input from memory
    input  MEM_TAG       mem_in_transaction_tag,
    input  MEM_BLOCK     mem_in_data,
    input  MEM_TAG       mem_in_data_tag,

    output MEM_COMMAND   mem_out_command,
    output ADDR          mem_out_addr,
    output MEM_BLOCK     mem_out_data,

    // Load (w/ load FU)
    input  ld2dcache ld_in,
    output dcache2ld ld_out,

    // Store (w/ SQ)
    input  sq2dcache sq_in,
    output dcache2sq sq_out
);
    // miss metadata
    struct packed {
        logic       vld;        // miss pending?
        logic       got;

        logic       is_load;    // store if not load
        MEM_TAG     miss_tag;
        ADDR        addr;
        MEM_BLOCK   dat;        // raw (unshifted/unextracted)
        // MEM_SIZE    size;
    } fill_md, fill_md_n;
    CACHE_HEADER cache_hdr, cache_hdr_n;

    logic [NUM_OPS-1:0] acc_req, acc_gnt; // arb memDP access
    logic [NUM_OPS-1:0] mem_req, mem_gnt; // arb fill/tag allocation

    logic       [NUM_SETS-1:0]  ren,  wen;
    WAY         [NUM_SETS-1:0]  rway, wway;            
    MEM_BLOCK   [NUM_SETS-1:0]  rdat, wdat;
    logic       [NUM_SETS-1:0][ASSOC-1:0] free_gnt;
    // logic       [NUM_SETS-1:0][ASSOC-1:0][$bits(MEM_BLOCK)-1:0] dbg_state;
    generate
        for (genvar s = 0; s < NUM_SETS; ++s) begin : gen_sets
            memDP #(
                .WIDTH     ($bits(MEM_BLOCK)),
                .DEPTH     (ASSOC),
                .READ_PORTS(1),
                .BYPASS_EN (0)
            ) set_i (
                // `ifdef DEBUG
                // .dbg(dbg_state[s]),
                // `endif
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
    CACHE_LOC   ld_loc;
    logic       ld_req;
    MEM_BLOCK   tmp_blk;
    // Load: index decode + port request
    always_comb begin
        ld_loc = cache_locate(cache_hdr, ld_in.addr);
        acc_req[LOAD] = ld_in.vld && ld_loc.hit;
        mem_req[LOAD] = ld_in.vld && !ld_loc.hit;

        tmp_blk = rdat[ld_loc.sid];

        ld_out = '{
            tag     : '0,
            dat     : tmp_blk.word_level[idw_word(ld_in.addr)],
            status  : acc_gnt[LOAD],
            ldb     : '0
        };
    end

    /* Store */
    // Store: index decode + port request
    CACHE_LOC st_loc;
    always_comb begin
        st_loc = cache_locate(cache_hdr, sq_in.addr);
        acc_req[STOR] = sq_in.vld && st_loc.hit;
        mem_req[STOR] = sq_in.vld && !st_loc.hit;

        sq_out = '{
            status : acc_gnt[STOR]
        };
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

    // /* Fill */ // TODO: Fill is stubbed
    // Fill: index decode + port request
    SID     fl_sid;
    WAY     fl_way;
    ADDR    fl_way_addr;
    logic   fl_way_dirty;
    always_comb begin
        fl_sid = get_sid(fill_md.addr);
        acc_req[FILL] = fill_md.vld && fill_md.got; 

        fl_way = '0;
        for (int w = 0; w < ASSOC; ++w) begin
            if (!alloc_msk[fl_sid][w])
                continue;
            fl_way |= w;
        end
        fl_way_dirty = cache_hdr.dirty[fl_sid][fl_way];
        fl_way_addr  = {
            cache_hdr.tag[fl_sid][fl_way],
            fl_sid,
            3'b0
        };

        mem_req[FILL] = acc_req[FILL]
            && evict[fl_sid]
            && fl_way_dirty;
    end


    // Action arbiter: which op gets to act this cycle? LOAD, STOR, or FILL?
    logic acc_en, mem_en;
    CACHE_OP_TAG acc_gnt_op, mem_gnt_op;
    always_comb begin
        acc_en      = 0;
        acc_gnt_op  = FILL;
        acc_gnt     = '0;
        for (int op = 0; op < NUM_OPS; ++op) begin
            if (!acc_req[op])
                continue;
            acc_en      = 1;
            acc_gnt[op] = 1;
            acc_gnt_op  = op;
            break;
        end

        mem_en      = 0;
        mem_gnt_op  = LOAD;
        mem_gnt     = '0;
        for (int op = 0; op < NUM_OPS; ++op) begin
            if (!mem_req[op])
                continue;
            mem_en      = !fill_md.vld;
            mem_gnt[op] = 1;
            mem_gnt_op  = op;
            break;
        end

        ren     = '0;
        wen     = '0;
        rway    = '0;
        wway    = '0;
        wdat    = '0;
        case (acc_gnt_op)
        FILL: begin
            ren[fl_sid]  = acc_en;
            wen[fl_sid]  = acc_en;
            rway[fl_sid] = fl_way;
            wway[fl_sid] = fl_way;
            wdat[fl_sid] = fill_md.dat;
        end
        LOAD: begin
            ren[ld_loc.sid]  = acc_en;
            rway[ld_loc.sid] = ld_loc.way;
        end
        STOR: begin
            ren[st_loc.sid]  = acc_en;
            wen[st_loc.sid]  = acc_en;
            rway[st_loc.sid] = st_loc.way;
            wway[st_loc.sid] = st_loc.way;
            wdat[st_loc.sid] = sq_in.dat;
        end
        default:;
        endcase

        fill_md_n = fill_md;
        mem_out_command = MEM_NONE;
        mem_out_addr    = '0;
        mem_out_data    = '0;
        if (mem_en) begin
            case (mem_gnt_op)
            FILL: begin
                fill_md_n = '{
                    vld     : mem_en,
                    got     : 0,

                    is_load : 0,
                    miss_tag: '0,   // fill below
                    addr    : dw_align(fl_way_addr),
                    dat     : rdat[fl_sid]
                };
            end
            LOAD: begin
                // TODO: for victim cache
                fill_md_n = '{
                    vld     : mem_en,
                    got     : 0,

                    is_load : 1,
                    miss_tag: '0,   // fill below
                    addr    : dw_align(ld_in.addr),
                    dat     : '0
                };
            end
            STOR: begin
                fill_md_n = '{
                    vld     : mem_en,
                    got     : 0,

                    is_load : 1,
                    miss_tag: '0,   // fill below
                    addr    : dw_align(sq_in.addr),
                    dat     : '0
                };
            end
            default:;
            endcase

            mem_out_command = fill_md_n.is_load ? MEM_LOAD : MEM_STORE;
            mem_out_addr    = fill_md_n.addr;
            mem_out_data    = fill_md_n.dat;

            /* ...
            WAIT UNTIL NEGATIVE EDGE
            ... */

            if (mem_in_transaction_tag != 0)
                fill_md_n.miss_tag = mem_in_transaction_tag;
            else
                fill_md_n = '0;

        end else if (fill_md.vld
            && mem_in_data_tag != 0
            && mem_in_data_tag == fill_md.miss_tag) begin
            fill_md_n.got = 1;
            fill_md_n.dat = mem_in_data;
        end
    end


    // Header update
    always_comb begin
        cache_hdr_n = cache_hdr;
        if (acc_en) begin
            case (acc_gnt_op)
            FILL: begin
                cache_hdr_n.vld[fl_sid][fl_way]     = 1;
                cache_hdr_n.dirty[fl_sid][fl_way]   = 0;
                cache_hdr_n.tag[fl_sid][fl_way]     = get_tag(fill_md.addr);
                // cache_hdr_n.age[fl_sid]          = TODO
            end
            LOAD: begin
                // TODO: LRU update (and victim update)
            end
            STOR: begin
                // TODO: LRU update
            end
            default:;
            endcase
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            cache_hdr <= '0;
            fill_md <= '0;
        end else begin
            cache_hdr <= cache_hdr_n;
            fill_md <= fill_md_n;
        end
    end
endmodule;