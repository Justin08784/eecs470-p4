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
        break; 
    end
    return '{hit, tag, way};
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
    logic       en;
    OP_TAG      op;

    logic       wr_mem;
    ADDR        addr;
    MEM_BLOCK   mem_data;
    MEM_SIZE    mem_size;
} MSHR_SND;

module fill_handler (
    // Metadata to consult
    input  CACHE_HEADER hdr,
    input  MSHR_ENTRY   mshr,

    /* orders */
    output logic        req,
    output READ_SND     r_snd,
    output WRIT_SND     w_snd,
    output MSHR_SND     mshr_snd,

    /* receipts */
    input  logic        gnt,
    input  READ_RCV     r_rcv
);
    OP_TAG op;
    WAY    way;

    always_comb begin
        req = mshr.status == S_FILL;

        way = get_way(mshr.addr);

        op = OP_NONE;
        if (req) begin
            op = hdr.vld[way]
                ? OP_FILL_EVICT
                : OP_FILL_NO_EVICT;
        end

        {r_snd, w_snd, mshr_snd} = '0;
        case (op)
            OP_FILL_EVICT: begin
                r_snd = '{
                    vld : 1,
                    way : way
                };

                w_snd = '{
                    vld : 1,
                    way : way,
                    dat : mshr.mem_data
                };

                mshr_snd = '{
                    op     : op,
                    en     : 1,
                    wr_mem : 1,
                    addr   : {hdr.tag[way], way, 3'b000},
                    mem_data : r_rcv.dat,
                    mem_size : DOUBLE
                };
            end

            OP_FILL_NO_EVICT: begin
                w_snd = '{
                    vld : 1,
                    way : way,
                    dat : mshr.mem_data
                };

                mshr_snd.op = op;
                mshr_snd.en = 1;
            end
            default:;
        endcase
    end

endmodule;

module load_handler (
    // Load (w/ load FU)
    input  ld2dcache    ld_in,
    output dcache2ld    ld_out,

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
    input  READ_RCV     r_rcv

);
    OP_TAG op;
    CACHE_LOC loc;
    assign w_snd = '0;

    always_comb begin
        req = ld_in.vld;

        loc = cache_locate(hdr, ld_in.addr);

        op = OP_NONE;
        if (req) begin
            op = loc.hit
                ? OP_LOAD_HIT
                : OP_LOAD_MISS;
        end

        {r_snd, mshr_snd} = '0;

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
                    en     : 1,
                    wr_mem : 0,
                    addr   : dw_align(ld_in.addr),
                    mem_data : '0,
                    mem_size : DOUBLE
                };
            end
            default:;
        endcase
    end

    always_comb begin
        ld_out = '{
            tag     : '0,
            dat     : r_rcv.dat, // FIXME: load FU will need to do the byte manip on the load!
            status  : gnt ? LD_SUCC : LD_FAIL,
            ldb     : '0
        };
    end

endmodule;

module stor_handler (
    input  sq2dcache    sq_in,
    output dcache2sq    sq_out,

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
    input  READ_RCV     r_rcv

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

        {r_snd, w_snd, mshr_snd} = '0;
        case (op)
            OP_STOR_HIT: begin
                r_snd = '{
                    vld : 1,
                    way : loc.way
                };

                w_snd = '{
                    vld : 1,
                    way : loc.way,
                    dat : apply_store(
                        sq_in.size, // size
                        sq_in.addr, // addr
                        sq_in.dat,  // wdat
                        r_rcv.dat   // prew
                    )
                };

            end

            OP_STOR_MISS: begin
                mshr_snd = '{
                    op     : op,
                    en     : 1,
                    wr_mem : 0,
                    addr   : dw_align(sq_in.addr),
                    mem_data : '0,
                    mem_size : DOUBLE
                };
            end
            default:;
        endcase
    end

    assign sq_out = '{
        status : gnt ? ST_SUCC : ST_FAIL
    };
endmodule;


module refill_engine (
    input reset,
    input clock,
    // expose mshr state
    output MSHR_ENTRY   mshr_out,

    input  MSHR_SND     snd_in,

    input  MEM_TAG      mem_in_transaction_tag,
    input  MEM_BLOCK    mem_in_data,
    input  MEM_TAG      mem_in_data_tag,

    output MEM_COMMAND  mem_out_command,
    output ADDR         mem_out_addr,
    output MEM_BLOCK    mem_out_data
);
    MSHR_ENTRY mshr, mshr_n;
    assign mshr_out = mshr;

    always_comb begin
        mshr_n = mshr;
        mem_out_command = '0;
        mem_out_addr    = '0;
        mem_out_data    = '0;

        case(mshr.status)
        S_IDLE: begin
            case ({snd_in.op, snd_in.en})
            {OP_LOAD_MISS, `TRUE}: begin
                mshr_n = '{
                    status   : S_NTAG,
                    wr_mem   : snd_in.wr_mem,
                    miss_tag : '0,
                    addr     : snd_in.addr,
                    mem_data : snd_in.mem_data,
                    mem_size : snd_in.mem_size
                };
            end
            {OP_STOR_MISS, `TRUE}: begin
                mshr_n = '{
                    status   : S_NTAG,
                    wr_mem   : snd_in.wr_mem,
                    miss_tag : '0,
                    addr     : snd_in.addr,
                    mem_data : snd_in.mem_data,
                    mem_size : snd_in.mem_size
                };
            end
            endcase
        end

        S_NTAG: begin
            if (mshr.wr_mem  && mem_in_transaction_tag != 0) begin
                mshr_n.miss_tag = mem_in_transaction_tag;
                mshr_n.status   = S_IDLE;
            end else if 
               (!mshr.wr_mem && mem_in_transaction_tag != 0) begin
                mshr_n.miss_tag = mem_in_transaction_tag;
                mshr_n.status   = S_WAIT;
            end
        end

        S_WAIT: begin
            if (mem_in_data_tag != 0
                && mem_in_data_tag == mshr.miss_tag) begin
                mshr_n.status   = S_FILL;
                mshr_n.mem_data = mem_in_data;
            end
        end

        S_FILL: begin
            case ({snd_in.op, snd_in.en})
            {OP_FILL_EVICT, `TRUE}: begin
                mshr_n = '{
                    status   : S_NTAG,
                    wr_mem   : snd_in.wr_mem,
                    miss_tag : '0,
                    addr     : snd_in.addr,
                    mem_data : snd_in.mem_data,
                    mem_size : snd_in.mem_size
                };
            end
            {OP_FILL_NO_EVICT, `TRUE}: begin
                mshr_n        = '0;
                mshr_n.status = S_IDLE;
            end
            default:;
            endcase
        end
        endcase
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            mshr <= '0;
        end else begin
            mshr <= mshr_n;
        end
    end


endmodule


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

    logic   ren,  wen;
    WAY     rway, wway;
    MEM_BLOCK rdat, wdat;
    logic [NUM_CACHE_LINES-1:0] free_gnt;
    logic [NUM_CACHE_LINES-1:0][$bits(MEM_BLOCK)-1:0] dbg_memDP;
    memDP #(
        .WIDTH     ($bits(MEM_BLOCK)),
        .DEPTH     (NUM_CACHE_LINES),
        .READ_PORTS(1),
        .BYPASS_EN (0)
    ) state (
        .dbg  (dbg_memDP),
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

    logic    [NUM_REQR-1:0] req, gnt;
    READ_SND [NUM_REQR-1:0] r_snds;
    WRIT_SND [NUM_REQR-1:0] w_snds;
    MSHR_SND [NUM_REQR-1:0] mshr_snds;

    READ_RCV [NUM_REQR-1:0] r_rcvs;

    REQR     gnt_reqr;
    always_comb begin
        gnt      = '0;
        gnt_reqr = '0;

        foreach (req[reqr]) begin
            if (!req[reqr])
                continue;
            gnt[reqr] = 1;
            gnt_reqr  = reqr;
            break;
        end

        r_rcvs = '0;
        ren  = 1;
        rway = r_snds[gnt_reqr];
        r_rcvs[gnt_reqr] = rdat;

        wen  = w_snds[gnt_reqr].vld;
        wway = w_snds[gnt_reqr].way;
        wdat = w_snds[gnt_reqr].dat;
    end




    // Resource managers
    MSHR_ENTRY mshr;
    // mshr manager
    refill_engine dec_refill (
        .reset,
        .clock,

        .mshr_out(mshr),
        .snd_in  (mshr_snds[gnt_reqr]),

        .mem_in_transaction_tag,
        .mem_in_data,
        .mem_in_data_tag,

        .mem_out_command,
        .mem_out_addr,
        .mem_out_data
    );

    // header manager
    WAY tmp_way;
    always_comb begin
        hdr_n = hdr;
        foreach (gnt[reqr]) begin
            if (!gnt[reqr])
                continue;

            case (reqr)
            REQR_FILL: begin
                tmp_way = w_snds[REQR_FILL].way;
                hdr_n.vld[tmp_way]      = 1;
                hdr_n.dirty[tmp_way]    = mshr.wr_mem;
                hdr_n.tag[tmp_way]      = get_tag(mshr.addr);
            end
            REQR_LOAD: begin
                // TODO: LRU update (and victim update)
            end
            REQR_STOR: begin
                // TODO: LRU update
            end
            default:;
            endcase

            break;
        end

    end

    // Request managers (for resource use intent)
    fill_handler dec_fill0 (
        .hdr,
        .mshr,

        .req        (req[REQR_FILL]),
        .r_snd      (r_snds[REQR_FILL]),
        .w_snd      (w_snds[REQR_FILL]),
        .mshr_snd   (mshr_snds[REQR_FILL]),

        .gnt        (gnt[REQR_FILL]),
        .r_rcv      (r_rcvs[REQR_FILL])
    );

    load_handler dec_load0 (
        .ld_in,
        .ld_out,
        .hdr,

        .req        (req[REQR_LOAD]),
        .r_snd      (r_snds[REQR_LOAD]),
        .w_snd      (w_snds[REQR_LOAD]),
        .mshr_snd   (mshr_snds[REQR_LOAD]),

        .gnt        (gnt[REQR_LOAD]),
        .r_rcv      (r_rcvs[REQR_LOAD])
    );

    stor_handler dec_stor0 (
        .sq_in,
        .sq_out,
        .hdr,

        .req        (req[REQR_STOR]),
        .r_snd      (r_snds[REQR_STOR]),
        .w_snd      (w_snds[REQR_STOR]),
        .mshr_snd   (mshr_snds[REQR_STOR]),

        .gnt        (gnt[REQR_STOR]),
        .r_rcv      (r_rcvs[REQR_STOR])
    );

    always_ff @(posedge clock) begin
        if (reset)
            hdr <= '0;
        else
            hdr <= hdr_n;
    end

    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  | >> DCACHE >>");
            $display("mem_in: {txn_tag: %2d, data_tag: %2d, data: %x}",
                mem_in_transaction_tag,
                mem_in_data_tag,
                mem_in_data
            );

            $display("mem_ot: {cmd: %s, addr: %x, data: %x}",
                dbg_mem_cmd(mem_out_command),
                mem_out_addr,
                mem_out_data
            );

            $display("ld_in: vld: %b, addr: 0x%x", ld_in.vld, ld_in.addr);
            $display("ld_ot: status: %s, tag: %2d, dat: 0x%x, ldb: %x",
                dbg_ld_status(ld_out.status),
                ld_out.tag,
                ld_out.dat,
                ld_out.ldb
            );

            $display("sq_in: vld: %b, addr: 0x%x, size: %s, dat: %1d",
                sq_in.vld,
                sq_in.addr,
                dbg_mem_size(sq_in.size),
                sq_in.dat
            );
            $display("sq_ot: status: %s",
                dbg_st_status(sq_out.status)
            );

            $display("");
            $display("mshr: {");
            $display("  status: %s\n  wr_mem: %b\n  miss_tag: %2d\n  addr: 0x%x\n  mem_data: 0x%x\n  mem_size: %s",
                dbg_mshr_status(mshr.status),
                mshr.wr_mem,
                mshr.miss_tag,
                mshr.addr,
                mshr.mem_data,
                dbg_mem_size(mshr.mem_size)
            );
            $display("}");

            $display("");
            for (int i = 0; i < NUM_CACHE_LINES; ++i) begin
                if (!hdr.vld[i]) begin
                    $display("header[%2d]:", i);
                    continue;
                end
                $display("header[%2d]: {vld: %b, dirty: %b, tag: 0x%x} data: %x, (addr: 0x%x)",
                    i,
                    hdr.vld[i],
                    hdr.dirty[i],
                    hdr.tag[i],
                    dbg_memDP[i],
                    {hdr.tag[i], WAY'(i), 3'b000}
                );
            end

            $display("  | << DCACHE <<");
        end
    end

endmodule