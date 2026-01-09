`include "sys_defs.svh"
`include "dcache_block_direct.svh"

// function automatic MEM_BLOCK apply_store(
//     input MEM_SIZE      size,
//     input ADDR          addr,
//     input DATA_BLOCK    wdat,
//     input MEM_BLOCK     prew
// );
//     MEM_BLOCK posw;
//     DW_ACCESS acc;
//     acc = '{
//         byte_off : idw_byte(addr),
//         half_off : idw_half(addr),
//         word_off : idw_word(addr)
//     };

//     posw = prew;
//     case (size)
//     BYTE  : posw.byte_level[acc.byte_off] = wdat.byte_level[0];
//     HALF  : posw.half_level[acc.half_off] = wdat.half_level[0];
//     WORD  : posw.word_level[acc.word_off] = wdat.word_level;
//     default:;
//     endcase

//     return posw;
// endfunction

function automatic MEM_BLOCK apply_store(
    input logic[3:0]    byte_mask,
    input ADDR          addr,
    input DATA_BLOCK    wdat,
    input MEM_BLOCK     prew
);
    MEM_BLOCK posw;
    logic word_off;
    DATA_BLOCK dst_word;
    posw = prew;
    word_off = idw_word(addr);
    dst_word = prew.word_level[word_off];
    posw.word_level[word_off] = bytewise_override(dst_word, wdat, byte_mask);
    return posw;
endfunction

typedef struct packed {
    logic       vld;
    TAG         tag;
    SID         sid;
    WAY         way;
} READ_SND;
typedef struct packed {
    MEM_BLOCK   dat;
} READ_RCV;

typedef struct packed {
    logic       vld;
    TAG         tag;
    SID         sid;
    WAY         way;
    MEM_BLOCK   dat;
} WRIT_SND;
typedef struct packed {
    logic       en;
    BMASK       msk;
    OP_TAG      op;

    logic       wr_mem;
    ADDR        addr;
    MEM_BLOCK   mem_data;
    MEM_SIZE    mem_size;
} MSHR_SND;

module fill_handler (
    input  logic        flush,
    input  BMASK        clmsk,

    // Metadata to consult
    input  CACHE_HEADER hdr,
    input  MSHR_ENTRY   mshr,

    input  logic[NUM_SETS-1:0][ASSOC-1:0] lruvs, // lru vectors
    input  WAY[NUM_SETS-1:0]    lru_ways,

    /* orders */
    output logic        req,
    output READ_SND     r_snd,
    output WRIT_SND     w_snd,
    output MSHR_SND     mshr_snd,

    /* receipts */
    input  logic        gnt,
    input  READ_RCV     r_rcv
);
    OP_TAG  op;
    TAG     tag, victim_tag;
    SID     sid;
    WAY     way;

    logic[NUM_SETS-1:0][ASSOC-1:0] lru_and_needs_evict; // is lru AND needs evict
    logic[NUM_SETS-1:0] lru_needs_evict;                // the lru way needs evict
    assign lru_and_needs_evict = lruvs & (hdr.vld & hdr.dirty);
    for (genvar s = 0; s < NUM_SETS; ++s)
        assign lru_needs_evict[s] = |lru_and_needs_evict[s];

    always_comb begin
        req = mshr.status == S_FILL & ~(flush & |(mshr.msk & clmsk));

        tag = get_tag(mshr.addr);
        sid = get_sid(mshr.addr);
        way = lru_ways[sid];
        victim_tag  = hdr.tag[sid][way];

        op =!req                ? OP_NONE :
            lru_needs_evict[sid]? OP_FILL_EVICT : OP_FILL_NO_EVICT;

        {r_snd, w_snd, mshr_snd} = '0;
        case (op)
        OP_FILL_EVICT: begin
            r_snd = '{
                vld : 1,
                tag : victim_tag,
                sid : sid,
                way : way
            };

            w_snd = '{
                vld : 1,
                tag : tag,
                sid : sid,
                way : way,
                dat : mshr.mem_data
            };

            mshr_snd = '{
                op     : op,
                en     : 1,
                msk    : 'x, // don't care
                wr_mem : 1,
                addr   : {victim_tag, sid, 3'b000},
                mem_data : r_rcv.dat,
                mem_size : DOUBLE
            };
        end

        OP_FILL_NO_EVICT: begin
            w_snd = '{
                vld : 1,
                tag : tag,
                sid : sid,
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
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  BMASK        clmsk,

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

    assign req  = ld_in.vld;
    assign loc  = cache_locate(hdr, ld_in.addr);
    assign op   =   !req    ? OP_NONE       :
                    loc.hit ? OP_LOAD_HIT   : OP_LOAD_MISS;
    always_comb begin
        r_snd   = '{
            vld     : 1'b0,     // overriden below
            tag     : loc.tag,
            sid     : loc.sid,
            way     : loc.way
        };

        mshr_snd= '{
            op      : op,
            en      : 1'b0,     // overriden below
            msk     : ld_in.msk,
            wr_mem  : 0,
            addr    : dw_align(ld_in.addr),
            mem_data: '0,
            mem_size: DOUBLE
        };

        unique case (op)
        OP_LOAD_HIT : r_snd.vld     = 1'b1;
        OP_LOAD_MISS: mshr_snd.en   = 1'b1;
        default:;
        endcase
    end

    logic ldb_vld;
    LDB ldb, ldb_n;
    assign ldb_n = '{
        vld_byte_mask   : '1,  // NOTE: always all 1s (only really useful for sq)
        lbuf_idx        : ld_in.lbuf_idx,
        dat             : r_rcv.dat.word_level[ld_in.addr[2]]
    };
    flop #(
        .WIDTH($bits(LDB))
    ) ldb_flop (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),
        .clmsk  (clmsk),

        .i_vld  (ld_in.dispatch_en),
        .i_msk  (ld_in.msk),
        .i_dat  (ldb_n),

        .o_vld  (ldb_vld),
        .o_msk  (),
        .o_dat  (ldb)
    );

    logic addr_in_bounds;
    assign addr_in_bounds = ld_in.addr < `MEM_SIZE_IN_BYTES;

    assign ld_out = '{
        // tag     : '0,
        // dat     : r_rcv.dat, // FIXME: load FU will need to do the byte manip on the load!
        status  : addr_in_bounds
            ? (gnt && op == OP_LOAD_HIT) ? LD_SUCC : LD_FAIL
            : req ? LD_SUCC : LD_FAIL,
                /* Marking OOB loads as "successful":
                Unlike stores (which wrmem only after retirement), loads can execute while
                on a wrong (branch) path, and so they can have wacky OOB addresses
                (e.g. 0x1000c which is out of bounds).
                
                Since mem.sv ignores OOB requests, this wrong path load is never satisfied,
                and so the load unit can stall forever.
                */
        ldb_vld : ldb_vld,
        ldb     : ldb
    };

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

    assign req  = sq_in.vld;
    assign loc  = cache_locate(hdr, sq_in.addr);

    assign op   =   !req    ? OP_NONE       :
                    loc.hit ? OP_STOR_HIT   : OP_STOR_MISS;

    always_comb begin
        r_snd = '{
            vld     : 1'b0,     // overriden below
            tag     : loc.tag,
            sid     : loc.sid,
            way     : loc.way
        };
        w_snd = '{
            vld     : 1'b0,     // overriden below
            tag     : loc.tag,
            sid     : loc.sid,
            way     : loc.way,
            dat     : apply_store(sq_in.has_byte_mask, sq_in.addr, sq_in.dat, r_rcv.dat)
        };

        mshr_snd = '{
            op       : op,
            en       : 1'b0,    // overriden below
            msk      : '0,      // store has retired; no unresolved branch dependencies
            wr_mem   : 0,
            addr     : dw_align(sq_in.addr),
            mem_data : '0,
            mem_size : DOUBLE
        };


        unique case (op)
        OP_STOR_HIT: begin
            r_snd.vld   = 1'b1;
            w_snd.vld   = 1'b1;
        end

        OP_STOR_MISS: begin
            mshr_snd.en = 1'b1;
        end
        default:;
        endcase
    end

    assign sq_out = '{
        status : (gnt && op == OP_STOR_HIT) ? ST_SUCC : ST_FAIL
    };
endmodule;


module refill_engine (
    input reset,
    input clock,
    input flush,
    input BMASK clmsk,
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
            {OP_LOAD_MISS, `TRUE},
            {OP_STOR_MISS, `TRUE}: begin
                mshr_n = '{
                    status   : S_NTAG,
                    msk      : snd_in.msk,
                    wr_mem   : snd_in.wr_mem,
                    mem_tag  : '0,
                    addr     : snd_in.addr,
                    mem_data : snd_in.mem_data,
                    mem_size : snd_in.mem_size
                };
            end
            endcase
        end

        S_NTAG: begin
            if (mshr.mem_tag == 0) begin
                mem_out_addr    = dw_align(mshr.addr);
                mem_out_data    = mshr.mem_data;
                mem_out_command = mshr.wr_mem ? MEM_STORE : MEM_LOAD;
            end

            if (mem_in_transaction_tag != 0) begin
                mshr_n.mem_tag  = mem_in_transaction_tag;
                mshr_n.status   = mshr.wr_mem ? S_IDLE : S_WAIT;
            end
        end

        S_WAIT: begin
            if (mem_in_data_tag != 0
            &&  mem_in_data_tag == mshr.mem_tag) begin
                mshr_n.status   = S_FILL;
                mshr_n.mem_data = mem_in_data;
            end
        end

        S_FILL: begin
            case ({snd_in.op, snd_in.en})
            {OP_FILL_EVICT, `TRUE}: begin
                mshr_n = '{
                    status   : S_NTAG,
                    msk      : '0,
                    wr_mem   : snd_in.wr_mem,
                    mem_tag  : '0,
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
        mshr <= mshr_n;

        if (reset
        |  (flush & |(mshr.msk & clmsk))) begin
        // ||  (flush && !mshr.wr_mem && mshr.mem_tag == 0)) begin
            /*
            FIXME: This seems rather hacky. During flush, clear a load request if it
            has not allocated mem_tag. This prevents the potentially spurious
            requests of ooo loads (e.g. oob addresses) from persisting in the dcache--
            dcache would get stuck requesting the bad address continuously.

            FIXME: This was disabled temporarily because–– for the meantime––
            we will not allow loads to complete in the presence of uncompleted loads
            (speculative load execution). May be needed later.
            */

            mshr.status <= S_IDLE;
            mshr.msk    <= '0;
        end
    end


endmodule


module dcache_block (
    output logic    any_pending,
    output DBG_dcache dbg,

    input logic clock,
    input logic reset,
    input logic flush,
    input BMASK clmsk,

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
    struct packed {
        logic       en;
        TAG         tag;
        SID         sid;
        WAY         way;
        MEM_BLOCK   dat;
    } w, w_n;   // flopped
    struct packed {
        TAG         tag;
        SID         sid;
        WAY         way;
    } r;        // combinational

    logic [NUM_SETS-1:0][ASSOC-1:0] lruvs;
    WAY [NUM_SETS-1:0]  lru_ways;
    WAY acc_way;
    AGE [NUM_SETS-1:0]  acc_age_n;

    generate
    for (genvar s = 0; s < NUM_SETS; ++s) begin
        lru_man #(.SETW(ASSOC)) lru_seti (
            .vld    (hdr.vld[s]),
            .age    (hdr.age[s]),
            .lruv   (lruvs[s]),
            .lru_way(lru_ways[s]),

            .msk_en (w.en),
            .msk_way(w.way),

            .acc_way(acc_way),
            .age_n  (acc_age_n[s])
        );
    end
    endgenerate


    logic[NUM_SETS-1:0]     wens;
    MEM_BLOCK[NUM_SETS-1:0] rdats;
    logic   [NUM_SETS-1:0][ASSOC-1:0][$bits(MEM_BLOCK)-1:0] dbg_memDP;

    always_comb begin
        wens        = '0;
        wens[w.sid] = w.en;
    end
    generate
    for (genvar s = 0; s < NUM_SETS; ++s) begin : gen_sets
        memDP #(
            .WIDTH     ($bits(MEM_BLOCK)),
            .DEPTH     (ASSOC),
            .READ_PORTS(1),
            .BYPASS_EN (0)
        ) set_i (
            .dbg  (dbg_memDP[s]),
            .clock,
            .reset,
            .re   (1'b1),
            .raddr(r.way),
            .rdata(rdats[s]),
            .we   (wens [s]),
            .waddr(w.way),
            .wdata(w.dat)
        );
    end
    endgenerate

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
        gnt_reqr= '0;
        gnt     = '0;
        for (int reqr = 0; reqr < NUM_REQR; ++reqr) begin
            if (req[reqr])
                gnt_reqr = reqr;
        end

        for (int reqr = 0; reqr < NUM_REQR; ++reqr) begin
            if (req[NUM_REQR-1 - reqr]) begin
                gnt[NUM_REQR-1 - reqr]= 1'b1;
                break;
            end
        end
    end

    assign w_n = '{
        en  : w_snds[gnt_reqr].vld,
        tag : w_snds[gnt_reqr].tag,
        sid : w_snds[gnt_reqr].sid,
        way : w_snds[gnt_reqr].way,
        dat : w_snds[gnt_reqr].dat
    };

    assign r = '{
        tag : r_snds[gnt_reqr].tag,
        sid : r_snds[gnt_reqr].sid,
        way : r_snds[gnt_reqr].way
    };

    always_comb
        r_rcvs[gnt_reqr].dat =
            w.en & ({r.tag, r.sid} == {w.tag, w.sid}) ? w.dat : rdats[r.sid];


    // Resource managers
    MSHR_ENTRY mshr;
    // mshr manager
    refill_engine dec_refill (
        .reset                  (reset),
        .clock                  (clock),
        .flush                  (flush),
        .clmsk                  (clmsk),

        .mshr_out               (mshr),
        .snd_in                 (mshr_snds[gnt_reqr]),

        .mem_in_transaction_tag (mem_in_transaction_tag),
        .mem_in_data            (mem_in_data),
        .mem_in_data_tag        (mem_in_data_tag),

        .mem_out_command        (mem_out_command),
        .mem_out_addr           (mem_out_addr),
        .mem_out_data           (mem_out_data)
    );

    // header manager
    always_comb begin
        hdr_n = hdr;
        foreach (gnt[reqr]) begin
            if ( gnt[reqr]) begin
                SID tmp_sid;
                WAY tmp_way;

                case (reqr)
                REQR_FILL: begin
                    tmp_sid = w_snds[REQR_FILL].sid;
                    tmp_way = w_snds[REQR_FILL].way;
                    hdr_n.vld   [tmp_sid][tmp_way]  = 1;
                    hdr_n.dirty [tmp_sid][tmp_way]  = mshr.wr_mem;
                    hdr_n.tag   [tmp_sid][tmp_way]  = get_tag(mshr.addr);

                    acc_way = tmp_way;
                    hdr_n.age   [tmp_sid] = acc_age_n[tmp_sid];
                end
                REQR_LOAD: begin
                    // TODO: LRU update (and victim update)
                    tmp_sid = r_snds[REQR_LOAD].sid;
                    tmp_way = r_snds[REQR_LOAD].way;

                    acc_way = tmp_way;
                    hdr_n.age   [tmp_sid] = acc_age_n[tmp_sid];
                end
                REQR_STOR: begin
                    // TODO: LRU update
                    tmp_sid = w_snds[REQR_STOR].sid;
                    tmp_way = w_snds[REQR_STOR].way;
                    hdr_n.dirty [tmp_sid][tmp_way] = 1;

                    acc_way = tmp_way;
                    hdr_n.age   [tmp_sid] = acc_age_n[tmp_sid];
                end
                default:;
                endcase
            end
        end

    end

    // Request managers (for resource use intent)
    fill_handler dec_fill0 (
        .flush      (flush),
        .clmsk      (clmsk),

        .hdr        (hdr),
        .mshr       (mshr),
        .lruvs      (lruvs),
        .lru_ways   (lru_ways),

        .req        (req        [REQR_FILL]),
        .r_snd      (r_snds     [REQR_FILL]),
        .w_snd      (w_snds     [REQR_FILL]),
        .mshr_snd   (mshr_snds  [REQR_FILL]),

        .gnt        (gnt        [REQR_FILL]),
        .r_rcv      (r_rcvs     [REQR_FILL])
    );

    load_handler dec_load0 (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .clmsk      (clmsk),

        .ld_in      (ld_in),
        .ld_out     (ld_out),
        .hdr        (hdr),

        .req        (req        [REQR_LOAD]),
        .r_snd      (r_snds     [REQR_LOAD]),
        .w_snd      (w_snds     [REQR_LOAD]),
        .mshr_snd   (mshr_snds  [REQR_LOAD]),

        .gnt        (gnt        [REQR_LOAD]),
        .r_rcv      (r_rcvs     [REQR_LOAD])
    );

    stor_handler dec_stor0 (
        .sq_in      (sq_in),
        .sq_out     (sq_out),
        .hdr        (hdr),

        .req        (req        [REQR_STOR]),
        .r_snd      (r_snds     [REQR_STOR]),
        .w_snd      (w_snds     [REQR_STOR]),
        .mshr_snd   (mshr_snds  [REQR_STOR]),

        .gnt        (gnt        [REQR_STOR]),
        .r_rcv      (r_rcvs     [REQR_STOR])
    );

    always_ff @(posedge clock) begin
        hdr <= hdr_n;
        w   <= w_n;

        if (reset) begin
            hdr.vld <= '0;
            w.en    <= 1'b0;
        end
    end

  
    assign any_pending = w.en | mshr.status != S_IDLE;
    assign dbg = '{
        hdr     : hdr,
        memDP   : dbg_memDP
    };

`ifdef DEBUG
    task print_dcache;
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

        $display("ld_in: vld: %b, lbuf_idx: %1d, addr: 0x%x, dispatch_en: %b",
            ld_in.vld,
            ld_in.lbuf_idx,
            ld_in.addr,
            ld_in.dispatch_en
        );
        $display("ld_ot: status: %s, ldb: {vld: %b, lbuf_idx: %1d, dat: 0x%x}",
            dbg_ld_status(ld_out.status),
            ld_out.ldb_vld,
            ld_out.ldb.lbuf_idx,
            ld_out.ldb.dat
        );

        $display("sq_in: vld: %b, addr: 0x%x, size: %s, dat: %x",
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
        $display("  status: %s\n  msk: %b\n  wr_mem: %b\n  mem_tag: %2d\n  addr: 0x%x\n  mem_data: 0x%x\n  mem_size: %s",
            dbg_mshr_status(mshr.status),
            mshr.msk,
            mshr.wr_mem,
            mshr.mem_tag,
            mshr.addr,
            mshr.mem_data,
            dbg_mem_size(mshr.mem_size)
        );
        $display("}");

        $display("");
        $display("mshr_n: {");
        $display("  status: %s\n  msk: %b\n  wr_mem: %b\n  mem_tag: %2d\n  addr: 0x%x\n  mem_data: 0x%x\n  mem_size: %s",
            dbg_mshr_status(dec_refill.mshr_n.status),
            dec_refill.mshr_n.msk,
            dec_refill.mshr_n.wr_mem,
            dec_refill.mshr_n.mem_tag,
            dec_refill.mshr_n.addr,
            dec_refill.mshr_n.mem_data,
            dbg_mem_size(dec_refill.mshr_n.mem_size)
        );
        $display("}");

        $display("gnt: %b, gnt_reqr: %d", gnt, gnt_reqr);
        $display("mshr_snds[gnt_reqr]: en: %b, op: %d, wr_mem: %b, addr: %x, mem_data: %d, mem_size: %d",
            mshr_snds[gnt_reqr].en,
            mshr_snds[gnt_reqr].op,
            mshr_snds[gnt_reqr].wr_mem,
            mshr_snds[gnt_reqr].addr,
            mshr_snds[gnt_reqr].mem_data,
            mshr_snds[gnt_reqr].mem_size
        );
        // .mshr_out               (mshr),
        // .snd_in                 (mshr_snds[gnt_reqr]),

        $display("");
        $display("gnt: %b", gnt);
        $display("dirty: %b\n", hdr.dirty);
        for (int s = 0; s < NUM_SETS; ++s) begin
            $display("set[%2d]:", s);
            for (int w = 0; w < ASSOC; ++w) begin
                if (!hdr.vld[s][w]) begin
                    $display("  blk[%1d]: ", w);
                    continue;
                end
                $display("  blk[%1d]: {dirty: %b, tag: 0x%x} data: %x, (addr: 0x%x)",
                    w,
                    hdr.dirty   [s][w],
                    hdr.tag     [s][w],
                    dbg_memDP   [s][w],
                    {hdr.tag[s][w], SID'(s), 3'b000}
                );
            end
        end

        $display("  | << DCACHE <<");
    endtask
`endif


endmodule