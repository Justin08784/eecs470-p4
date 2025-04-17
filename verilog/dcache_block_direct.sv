`include "sys_defs.svh"
`include "dcache_block_direct.svh"

typedef struct packed {
    logic   hit;
    TAG     tag;
    WAY     way;
} CACHE_LOC;

function automatic CACHE_LOC cache_locate(
    input CACHE_HEADER hdr,
    input ADDR addr
);
    logic   hit;
    TAG     tag;
    WAY     way;
    tag = get_tag(addr);
    hit = 0;
    way = '0;
    for (int w = 0; w < NUM_CACHE_LINES; ++w) begin
        if (!(hdr.vld[w] && tag == hdr.tag[w]))
            continue;
        way = w;
        hit = 1;
    end
    return '{hit, tag, way};
endfunction

typedef struct packed {
    logic       vld;
    WAY         way;
} READ_SND;
typedef struct packed {
    MEM_BLOCK   dat;
} READ_RCV;

typedef struct packed {
    logic       vld;
    WAY         way;
    MEM_BLOCK   dat;
} WRIT_SND;
typedef struct packed {
    logic _placeholder;
} WRIT_RCV;

typedef struct packed {
    logic       vld;
    OP_TAG      op;

    logic       wr_mem;
    ADDR        addr;
    MEM_BLOCK   mem_data;
    MEM_SIZE    mem_size;
} MSHR_SND;
typedef struct packed {
    logic _placeholder;
} MSHR_RCV;

module decode_fill (
    // Metadata to consult
    input  CACHE_HEADER hdr,
    input  MSHR_ENTRY   mshr,
    input  logic        evict,
    input  logic        [NUM_CACHE_LINES-1:0] alloc_msk,

    /* orders */
    output logic        req,
    output READ_SND     r_snd,
    output WRIT_SND     w_snd,
    output MSHR_SND     mshr_snd,

    /* receipts */
    input  logic        gnt,
    output READ_RCV     r_rcv,
    output WRIT_RCV     w_rcv,
    output MSHR_RCV     mshr_rcv
);
    OP_TAG op;
    WAY    way;

    always_comb begin
        req = mshr.status == S_FILL;

        op = OP_NONE;
        if (req) begin
            op = evict
                ? OP_FILL_EVICT
                : OP_FILL_NO_EVICT;
        end

        way = '0;
        foreach (alloc_msk[w]) begin
            if (!alloc_msk[w])
                continue;
            way = w;
        end

        {
            r_snd,
            w_snd,
            mshr_snd
        } = '0;
        case (op)
            OP_FILL_EVICT: begin
                r_snd = '{
                    vld : 1,
                    way : way
                };

                w_snd = '{
                    vld : 1,
                    way : way,
                    dat : mshr.mem_data// FIXME!!!: You need to apply store correctly here!
                };

                mshr_snd = '{
                    op     : op,
                    vld    : 1,
                    wr_mem : 1,
                    addr   : 32'hdeadbeef, // FIXME::: reconstruct the address of the tobeevicted block
                    mem_data : r_rcv.dat,
                    mem_size : DOUBLE
                };
            end

            OP_FILL_NO_EVICT: begin
                w_snd = '{
                    vld : 0,
                    way : way,
                    dat : mshr.mem_data// FIXME!!!: You need to apply store correctly here!
                };

                mshr_snd.op = op;
                mshr_snd.vld= 1;
            end
            default:;
        endcase
    end

endmodule;

module decode_load (
    // Load (w/ load FU)
    input  ld2dcache    ld_in,

    // Metadata to consult
    input  CACHE_HEADER hdr,
    // TODO: add victim cache (some way to consult metadata; victim cache needs header?)

    /* orders */
    output logic        req,
    output READ_SND     r_snd,
    output MSHR_SND     mshr_snd,

    /* receipts */
    input  logic        gnt,
    output READ_RCV     r_rcv

);
    OP_TAG op;
    CACHE_LOC loc;

    always_comb begin
        req = ld_in.vld;

        loc = cache_locate(hdr, ld_in.addr);

        op = OP_NONE;
        if (req) begin
            op = loc.hit
                ? OP_LOAD_HIT
                : OP_LOAD_MISS;
        end

        {
            r_snd,
            mshr_snd
        } = '0;

        case (op)
            OP_LOAD_HIT: begin
                r_snd = '{
                    vld : 1,
                    way : loc.way
                };
            end

            OP_LOAD_MISS: begin
                mshr_snd = '{
                    op     : op,
                    vld    : 1,
                    wr_mem : 0,
                    addr   : ld_in.addr, // FIXME::: reconstruct the address of the tobeevicted block
                    mem_data : '0,
                    mem_size : DOUBLE
                };
            end
            default:;
        endcase
    end

endmodule;

module decode_stor (
    input  sq2dcache    sq_in,

    // Metadata to consult
    input  CACHE_HEADER hdr,
    // TODO: add victim cache (some way to consult metadata; victim cache needs header?)

    /* orders */
    output logic        req,
    output READ_SND     r_snd,
    output WRIT_SND     w_snd,
    output MSHR_SND     mshr_snd,

    /* receipts */
    input  logic        gnt,
    output READ_RCV     r_rcv

);
   OP_TAG op;
   CACHE_LOC loc;

    always_comb begin
        loc = cache_locate(hdr, sq_in.addr);
        req = sq_in.vld;

        op = OP_NONE;
        if (req) begin
            op = loc.hit
                ? OP_STOR_HIT
                : OP_STOR_MISS;
        end

        {
            r_snd,
            w_snd,
            mshr_snd
        } = '0;
        case (op)
            OP_FILL_EVICT: begin
                r_snd = '{
                    vld : 1,
                    way : loc.way
                };

                w_snd = '{
                    vld : 1,
                    way : loc.way,
                    dat : r_rcv.dat // FIXME!!!: You need to apply store correctly here!
                };

            end

            OP_FILL_NO_EVICT: begin
                mshr_snd = '{
                    op     : op,
                    vld    : 1,
                    wr_mem : 0,
                    addr   : sq_in.addr, // FIXME::: reconstruct the address of the tobeevicted block
                    mem_data : '0,
                    mem_size : DOUBLE
                };
            end
            default:;
        endcase
    end

endmodule;


module dcache_block (
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
    CACHE_HEADER hdr, hdr_n;
    MSHR_ENTRY   mshr, mshr_n;

    logic   ren,  wen;
    WAY     rway, wway;
    MEM_BLOCK rdat, wdat;
    logic [NUM_CACHE_LINES-1:0] free_gnt;
    memDP #(
        .WIDTH     ($bits(MEM_BLOCK)),
        .DEPTH     (NUM_CACHE_LINES),
        .READ_PORTS(1),
        .BYPASS_EN (0)
    ) state (
        .clock(clock),
        .reset(reset),
        .re   (ren ),
        .raddr(rway),
        .rdata(rdat),
        .we   (wen ),
        .waddr(wway),
        .wdata(wdat)
    );

    psel_gen #(
        .WIDTH(NUM_CACHE_LINES),
        .REQS(1)
    ) free_way (
        .req (~hdr.vld),
        .gnt (free_gnt)
    );

    typedef enum logic[1:0] {
        REQR_STOR, // lowest priority
        REQR_LOAD, // ...
        REQR_FILL, // highest priority
        NUM_REQR
    } REQR;
    logic [NUM_REQR-1:0] req, gnt;


    logic   evict; // alloc in set requires evict? i.e. !(any free way in set)
    logic   [NUM_CACHE_LINES-1:0] alloc_msk; // alloc in set requires evict? i.e. !(any free way in set)
    logic   [NUM_CACHE_LINES-1:0] lru; // lru victim way
    always_comb begin
        evict = !(|free_gnt);

        foreach(lru[w])
            lru[w] = w == 0;

        foreach(alloc_msk[w]) begin
            alloc_msk[w] = evict
                ? lru[w]
                : free_gnt[w];
        end
    end

    // microp decoders (for resource use intent)
    decode_fill dec_fill0 (
        .hdr,
        .mshr,
        .evict,
        .alloc_msk,

        .req(req[REQR_FILL])
    );

    decode_load dec_load0 (
        .ld_in,
        .hdr,

        .req(req[REQR_LOAD])
    );

    decode_stor dec_stor0 (
        .sq_in,
        .hdr,

        .req(req[REQR_STOR])
    );

endmodule