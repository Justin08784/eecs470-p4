`include "sys_defs.svh"
`include "execute.svh"
`include "dcache.svh"

function automatic DATA_BLOCK bytewise_override(
    input DATA_BLOCK  dst,
    input DATA_BLOCK  src,
    input logic [3:0] src_bmask
);
    DATA_BLOCK rv;
    rv = dst;
    foreach (src.byte_level[b]) begin
        if (!src_bmask[b])
            continue;
        rv.byte_level[b] = src.byte_level[b];
    end
    return rv;
endfunction

function automatic DATA_BLOCK extract_load(
    input ADDR        addr,
    input DATA_BLOCK  raw,
    input MEM_SIZE    size
);
    DATA_BLOCK rv;
    DW_ACCESS acc;
    acc = '{
        byte_off : idw_byte(addr),
        half_off : idw_half(addr),
        word_off : idw_word(addr)
    };

    rv = '0;
    case (size)
        BYTE  : rv = raw.byte_level[acc.byte_off];
        HALF  : rv = raw.half_level[acc.half_off];
        WORD  : rv = raw.word_level;
        default:;
    endcase
    return rv;
endfunction

module fake_dcache #(
    parameter int NUM_RPORTS=1
) (
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
    output dcache2sq sq_out,

    // LDB
    output LDB ldb_out
);
    always_comb begin
        ld_out = '0;
        ld_out.status = LD_HIT_WAIT;

        sq_out = '0;
        sq_out.status = ST_FAIL;

        ldb_out = '0;
    end
endmodule

module lod_ex(
    input clock,
    input reset,
    input flush,

    /* FRONTEND */
    output logic    [`NUM_FU_LOAD-1:0]  i_rdy,
        // ready to accept from regs.o_dat.lod?
    input  logic    [`NUM_FU_LOAD-1:0]  i_vld,
        // insns to accept from regs.o_dat.lod
    input  LOD_REGS [`NUM_FU_LOAD-1:0]  i_regs,
        // insn metadata/operands

    input  dcache2ld dcache_in,
    output ld2dcache dcache_out,
    
    input   sq2execute sq_in,
    output  execute2sq sq_out,
    output  execute2lq lq_out,
    output  executeLD2sq ld_sq_out,

    /* BACKEND */
    output logic    [`NUM_FU_LOAD-1:0]  o_vld,
    output CPL_CAND [`NUM_FU_LOAD-1:0]  o_cands,
    input  logic    [`NUM_FU_LOAD-1:0]  o_rdy 
        // completion grant
);
    /* TODO: Handling partial completes from the SQ
    If the SQ only supplies a subset of the bytes needed, then we need to get
    the rest of the bytes from the dcache.
    */
    localparam BAY_SZ = `LD_BAY_SZ;
    typedef struct packed {
        logic           vld;

        logic           queried;
        logic           hit;        // ...in cache (== !miss). Could update each cycle via recheck.
        // hit, retry 
        logic [3:0]     need_byte_mask;
        DATA_BLOCK      raw_dat;    // raw word from SQ/dcache. SHOULD NOT BE SHIFTED!
                                    // ...actually should we just let SQ, dcache do the shifting?
                                    // I think no...?
        // miss, retry
        MEM_TAG         miss_tag;   // valid iff miss_tag != 0

        // where to look / byte manip.
        LSQ_IDX         sq_idx;
        ADDR            addr;
        MEM_SIZE        mem_size;

        // CDB destination info
        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;
    } LOAD_BAY_ENTRY;
    LOAD_BAY_ENTRY  [BAY_SZ-1:0] bay, bay_n;
    logic           [BAY_SZ-1:0] bay_vld;

    localparam LDBUF_SZ = 8;// LSQ_SZ/2;
    typedef struct packed {
        logic           vld;

        logic           got; // got data?
        DATA_BLOCK      dat;
        /*
        FIXME: Do we need to query SQ from the load buffer? We're waiting
        for the fill anyways, so no right? If not query SQ, we can get rid of
        need_byte_mask (since the whole double-word will fill) and sq_idx?
        */
        MEM_TAG         miss_tag;

        // byte manip.
        DW_ACCESS       acc;
        MEM_SIZE        mem_size;

        // CDB destination info
        PHYS_REG_IDX    t;
        ROB_IDX         rob_idx;
    } LOAD_BUF_ENTRY;
    LOAD_BUF_ENTRY  [LDBUF_SZ-1:0] ldbuf, ldbuf_n;
    logic           [LDBUF_SZ-1:0] ldbuf_vld;

    // Arb: Give which free bay entry to entering, if any?
    logic [BAY_SZ-1:0]   bay_rdy_gnt;
    always_comb begin
        foreach (bay_vld[i])
            bay_vld[i] = bay[i].vld;
        i_rdy[0] = |(~bay_vld);
    end

    psel_gen #(
        .WIDTH  (BAY_SZ),
        .REQS   (1)
    ) arb_bay_rdy (
        .req    (~bay_vld),
        .gnt    (bay_rdy_gnt)
    );

    // Arb: Who "dispatches" from load bay to load buffer?
    logic [BAY_SZ-1:0] dispatch_vld; // who is eligible to advance?
    logic [BAY_SZ-1:0][BAY_SZ-1:0]   dispatch_gbus;
    logic [BAY_SZ-1:0][LDBUF_SZ-1:0] buf_rdy_gbus;

    logic [BAY_SZ-1:0] dispatch_en;  // who will advance?
    logic [BAY_SZ-1:0][LDBUF_SZ-1:0] bay2buf_gbus;  // who will advance?
    always_comb begin
        foreach (ldbuf_vld[i])
            ldbuf_vld[i] = ldbuf[i].vld;

        foreach (dispatch_vld[i]) begin
            dispatch_vld[i] = bay[i].vld && (
                !(|bay[i].need_byte_mask)   // data ready
              || (bay[i].miss_tag != 0)     // MSHR alloc'd
            );
        end

        dispatch_en = '0;
        bay2buf_gbus = '0;
        foreach (dispatch_gbus[i, j]) begin
            if (!dispatch_gbus[i][j])
                continue;
            dispatch_en[j]  |= |buf_rdy_gbus[i];
            bay2buf_gbus[j] |= buf_rdy_gbus[i];
        end
    end

    psel_gen #(
        .WIDTH  (LDBUF_SZ),
        .REQS   (BAY_SZ)
    ) arb_ldbuf_rdy (
        .req    (~ldbuf_vld),
        .gnt_bus(buf_rdy_gbus)
    );

    psel_gen #(
        .WIDTH  (BAY_SZ),
        .REQS   (BAY_SZ)
    ) arb_bay2buf (
        .req    (dispatch_vld),
        .gnt_bus(dispatch_gbus)
    );

    // Arb: Who in bay gets to query (both dcache and SQ)?
    logic [BAY_SZ-1:0] bay_hit_need;     // 1. !queried || hit
    logic [BAY_SZ-1:0] bay_miss_need;    // 2. queried  && !hit
    logic [BAY_SZ-1:0] bay_req_query;
    logic [BAY_SZ-1:0] bay_gnt_query;
    always_comb begin
        foreach (bay_hit_need[i])
            bay_hit_need[i] = bay[i].vld
                && |bay[i].need_byte_mask
                && (!bay[i].queried || bay[i].hit);
        foreach (bay_miss_need[i])
            bay_miss_need[i] = bay[i].vld
                && |bay[i].need_byte_mask
                && (bay[i].queried && !bay[i].hit);

        // give priority to hit need
        bay_req_query = |bay_hit_need
            ? bay_hit_need
            : bay_miss_need;
    end
    psel_gen #(
        .WIDTH  (BAY_SZ),
        .REQS   (1)
    ) arb_query (
        .req    (bay_req_query),
        .gnt    (bay_gnt_query)
    );

    ADDR            tmp_addr;
    MEM_SIZE        tmp_size;
    DW_ACCESS       tmp_acc;
    union packed {
        logic [3:0]     byte_level;
        logic [1:0][1:0]half_level;
        logic      [3:0]word_level;
    } tmp_bmask;

    always_comb begin
        bay_n = bay;

        // Handle incoming
        foreach (bay_rdy_gnt[i]) begin
            if (!(i_vld[0] && bay_rdy_gnt[i]))
                continue;
            tmp_addr = i_regs[i].rs1 + i_regs[i].dat.opb;
            tmp_size = i_regs[i].dat.mem_size;
            tmp_acc = '{
                byte_off : idw_byte(tmp_addr),
                half_off : idw_half(tmp_addr),
                word_off : idw_word(tmp_addr)
            };

            tmp_bmask = '0;
            case (tmp_size)
                BYTE  : tmp_bmask.byte_level[tmp_acc.byte_off] = '1;
                HALF  : tmp_bmask.half_level[tmp_acc.half_off] = '1;
                WORD  : tmp_bmask.word_level                   = '1;
                default:;
            endcase

            bay_n[i] = '{
                vld             : 1,
                queried         : 0,
                hit             : 0,
                need_byte_mask  : tmp_bmask,
                raw_dat         : '0,
                miss_tag        : 0,
                sq_idx          : i_regs[0].dat.sq_idx,
                addr            : tmp_addr,
                mem_size        : tmp_size,
                t               : i_regs[0].dat.t,
                rob_idx         : i_regs[0].dat.rob_idx
            };
        end

        // Handle sq, dcache output
        ld_sq_out = '0;
        dcache_out = '0;
        foreach (bay_gnt_query[i]) begin
            if (!bay_gnt_query[i])
                continue;

            ld_sq_out.forward_req_en[0]     = 1;
            ld_sq_out.forward_addr[0]       = bay[i].addr;
            ld_sq_out.forward_mem_size[0]   = bay[i].mem_size;
            ld_sq_out.forward_sq_idx[0]     = bay[i].sq_idx;

            dcache_out = '{
                vld : 1,
                addr: bay[i].addr
            };
        end

        // Handle SQ + dcache input (combine)
        foreach (bay_gnt_query[i]) begin
            if (!bay_gnt_query[i])
                continue;
            bay_n[i].queried = 1;

            if (sq_in.forward_en[0]) begin
                bay_n[i].raw_dat = bytewise_override(
                    bay_n[i].raw_dat,       // dst
                    sq_in.forward_data,     // src
                    sq_in.forward_byte_en   // src_bmask
                );

                bay_n[i].need_byte_mask &= ~sq_in.forward_byte_en[0];
            end

            case (dcache_in.status)
                LD_HIT_READ: begin
                    bay_n[i].hit = 1;
                    bay_n[i].need_byte_mask = '0;
                    bay_n[i].raw_dat = dcache_in.dat;
                end
                LD_HIT_WAIT: begin
                    bay_n[i].hit = 1;
                end
                LD_MISS_YTAG: begin
                    bay_n[i].hit = 0;
                    bay_n[i].miss_tag = dcache_in.tag;
                end
                LD_MISS_NTAG: begin
                    bay_n[i].hit = 0;
                end
            endcase
        end

        // Handle bay2buf advance
        ldbuf_n = ldbuf;
        foreach (dispatch_en[i])
            bay_n[i] = '0;
        foreach (bay2buf_gbus[i, j]) begin
            if (!bay2buf_gbus[i][j])
                continue;
            
            ldbuf_n[j] = '{
                vld     : 1,
                got     : !(|bay[i].need_byte_mask),
                dat     : bay[i].raw_dat,
                miss_tag: bay[i].miss_tag,
                acc     : '{
                    byte_off : idw_byte(bay[i].addr),
                    half_off : idw_half(bay[i].addr),
                    word_off : idw_word(bay[i].addr)
                },
                mem_size: bay[i].mem_size,
                t       : bay[i].t,
                rob_idx : bay[i].rob_idx
            };
        end
    end


    always_ff @(posedge clock) begin
        if (reset || flush) begin
            bay     <= '0;
            ldbuf   <= '0;
        end else begin
            bay     <= bay_n;
            ldbuf   <= ldbuf_n;
        end
    end


    // FIXME: placeholder
    assign o_vld = '0;


    /* TODO: CAND generation logic. Also, how do we know when
    a load result is ready without an lq2execute line? */
endmodule