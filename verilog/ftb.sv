`include "sys_defs.svh"

typedef struct packed {
    logic       vld1, vld2;
    WADDR       tgt1, tgt2;
    logic [3:0] off1, off2;
    logic       always_take1, always_take2;
    struct packed {
        logic cond; // = "sharing" bit
        logic call;
        logic ret;
        logic jalr;
    } md2; // re: br2/tail_slot
} FTB_ENTRY;

module ftb #(
    parameter NUM_LINES=1024,
    parameter ASSOC = 4
) (
    input clock,
    input reset,

    // fetch query
    input   WADDR       i_qry, // branch pc

    output  logic       o_vld,
    output  FTB_ENTRY   o_tgt,

    // puq updates
    input   struct packed {
        logic       en;
        WADDR       pc;
        FTB_ENTRY   dat;
    } i_upd
);
    localparam NUM_SETS     = NUM_LINES / ASSOC;
    localparam SID_BITS     = $clog2(NUM_SETS);
    localparam TAG_SKIMP    = 3;
    /*
    TAG_SKIMP = how many bits to drop from the full tag that is required to
    eliminate aliases (0 for no alias).

    Increasing will result in more aliases, but acceptable for
    BTB since they are speculative. Can be worth to save area and logic.
    */
    localparam TAG_BITS     = $bits(WADDR) - SID_BITS - TAG_SKIMP;
    typedef logic [SID_BITS-1:0] SID;
    typedef logic [TAG_BITS-1:0] TAG;
    typedef logic [$clog2(ASSOC)-1:0]   WAY;
    typedef logic [ASSOC-1:0][ASSOC-1:0]AGE;

    function automatic TAG get_tag(input WADDR waddr);
        return waddr[SID_BITS+TAG_BITS-1:SID_BITS];
    endfunction
    function automatic SID get_sid(input WADDR waddr);
        return waddr[SID_BITS-1:0];
    endfunction

    typedef struct packed {
        logic   [NUM_SETS-1:0][ASSOC-1:0] vld;
        TAG     [NUM_SETS-1:0][ASSOC-1:0] tag;
        /* TODO: implement pLRU (tree or bit) for assoc ≥ 8.
        Maybe auto-switch between LRU and pRLU according to assoc
        parameter, keeping LRU for assoc < 8. 
        
        TODO: We can save bits in the LRU age matrix by storing the upper-triangle
        bits (top right above diagonal). */
        AGE     [NUM_SETS-1:0] age;
    } HEADER;
    HEADER hdr, hdr_n;
    FTB_ENTRY [NUM_SETS-1:0][ASSOC-1:0] tgt, tgt_n;

    typedef struct packed {
        logic   hit;
        TAG     tag;
        WAY     way;
        SID     sid;
    } LOC;
    function automatic LOC locate(
        input HEADER    hdr,
        input WADDR     waddr
    );
        logic   hit;
        TAG     tag;
        WAY     way;
        SID     sid;
        tag = get_tag(waddr);
        sid = get_sid(waddr);

        way = 0;
        hit = 0;
        for (int w = 0; w < ASSOC; ++w) begin
            if (hdr.vld[sid][w] && (tag == hdr.tag[sid][w])) begin
                hit = 1;
                way = w;
                break;
            end
        end

        return '{
            hit : hit,
            tag : tag,
            way : way,
            sid : sid
        };
    endfunction

    function automatic AGE update_lru(
        input AGE age,
        input WAY way
    );
        AGE rv;
        rv = age;
        foreach(rv[i, j]) begin
            if (i == way)
                rv[i][j] = i == j;
            else if (j == way)
                rv[i][j] = 1;
        end
        return rv;
    endfunction

    // s1: tag access
    // s2: data access
    struct packed {
        logic   hit;
        SID     sid;
        WAY     way;
    } s1r, s1r_n;

    struct packed {
        logic   en;
        SID     sid;
        TAG     tag;
        WAY     way;
        FTB_ENTRY dat;
    } s1w, s1w_n;

    // fetch
    always_comb begin
        // s1
        LOC loc;
        loc = locate(hdr, i_qry);

        s1r_n = '{
            hit : loc.hit,
            sid : loc.sid,
            way : loc.way
        };

        // s2
        o_vld = s1r.hit;
        o_tgt = tgt[s1r.sid][s1r.way];
    end

    // retire
    always_comb begin
        // s1
        logic [NUM_SETS-1:0][ASSOC-1:0] lru;
        logic [NUM_SETS-1:0][$clog2(ASSOC)-1:0] ways;
        LOC loc;

        foreach (lru[s, w])
            lru[s][w] = &hdr.age[s][w];

        ways = '0;
        foreach (ways[s]) begin
            for (int w = 0; w < ASSOC; ++w) begin
                if (lru[s][w])
                    ways[s] = w;
            end
        end
        
        loc = locate(hdr, i_upd.pc);

        s1w_n = '{
            en  : i_upd.en,
            sid : loc.sid,
            tag : loc.tag,
            way : ways[loc.sid],
            dat : i_upd.dat
        };

        // s2
        hdr_n = hdr;
        tgt_n = tgt;

        // if (i_upd.en && !loc.hit) begin // dedup (dont insert if already there)
        // ^^ This dedup rule should no longer be valid if must be able to selectively
        // overwrite parts of existing FTB entries.
        if (s1w.en) begin
            hdr_n.vld[s1w.sid][s1w.way] = 1;
            hdr_n.tag[s1w.sid][s1w.way] = s1w.tag;
            hdr_n.age[s1w.sid]          = update_lru(hdr.age[s1w.sid], s1w.way);
            /* TODO: since every branch queries the FTB (but not every branch
            generates an FTB update) we need an LRU update for reads as well,
            not just writes. */
            tgt_n[s1w.sid][s1w.way]     = i_upd.dat;
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            hdr <= '{
                vld : '0,
                tag : '0,
                age : '1 // *IMPORTANT* empty lines are treated as "oldest"
            };
            tgt <= '0;
            s1r <= '0;
            s1w <= '0;
        end else begin
            hdr <= hdr_n;
            tgt <= tgt_n;
            s1r <= s1r_n;
            s1w <= s1w_n;
        end
    end


`ifdef DEBUG
    task automatic print_ftb();
        for (int s = 0; s < NUM_SETS; ++s) begin
            if (!(|hdr.vld[s]))
                continue;
            $display("set[%2d]:", s);
            for (int w = 0; w < ASSOC; ++w) begin
                if (!hdr.vld[s][w]) begin
                    $display("  %1d:", w);
                    continue;
                end
                $display("  %1d: {tag: 0x%x tgt: %x} ",
                    w,
                    hdr.tag[s][w],
                    w2addr(tgt[s][w])
                );
            end
        end
    endtask
`endif
endmodule
