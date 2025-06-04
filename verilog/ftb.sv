`include "sys_defs.svh"

typedef struct packed {
    // fallthrough npc (i.e. npc if no branch taken)
    logic [3:0] ft_lo4;     // LSB 4-bits
    logic       ft_cry;     // carry: does adding ft_off into base overflow a 4-bit offset
                            // (i.e. generate carry into bit 4)?
        /*
        has_end := does [base, base + 16) contain an FB-ending branch
        (i.e. a cond branch that was taken at least once or an uncond branch)?
        end_off := 4-bit offset from base to last FB-ending branch, if any

        logic [4:0] ft_off = has_end ? end_off + 1 : 16;
        ft_npc = base + ft_off;

        In retire, we compute ft_lo4, ft_cry as follows...
        logic [4:0] cry_sum;
        cry_sum = base[3:0] + ft_off;
        ft_lo4 = cry_sum[3:0];
        ft_cry = cry_sum[4];

        ...so that in BPU/pc-gen we can efficiently reconstruct ft_npc:
        ft_npc[:4]  = base[:4] + ft_cry;
        ft_npc[3:0] = ft_lo4;
        */

    // two branch slots: [0, 1]
    struct packed {
        logic       vld;
        WADDR       tgt;
        logic [3:0] off;
        logic       always_take;
    } [1:0] br_slot;

    // metadata re: br1/tail slot
    struct packed {
        logic cond;         // = "sharing" bit
        logic call;
        logic ret;
        logic jalr;
    } md1;
} FTB_ENTRY;

typedef struct packed {
    logic [3:0] ft_lo4;
    logic       ft_cry;

    struct packed {
        logic       vld;
        logic [3:0] off;
        logic       always_take;
    } [1:0] br_slot;

    logic       cond;   // is br1 conditional?
} FTB_ENTRY_vFTQ;

typedef struct packed {
    WADDR base;         // base address of FB

    logic take;         // any taken?
    logic take_slot;    // if so which branch slot?

    FTB_ENTRY_vFTQ fb;  // pared down FTB entry
} _FTQ_ENTRY;

typedef struct packed {
`ifdef DEBUG
    BMASK   b1hot;
`endif
    WADDR   PC;

    /* TODO: have a single take, tgt field, initialized by the BPU, but later
    overwritten by decode/EX when the branch resolves */
    logic   pred;
    WADDR   pred_tgt;
    logic   take;
    WADDR   tgt;

    logic   ret;    // is a ret instruction? (heuristic only; see predecoder for spec)
    logic   cond;   // is a conditional branch?

    logic   [GHR_LEN-1:0] hash; // gshare hash index
    logic   [`N-1:0][$clog2(GHR_BUF_SZ)-1:0] ghr_base;
    logic   pred_bim;
    logic   pred_gshare;

    logic   [$clog2(`FTQ_SZ)-1:0] ftq_idx; // pointer to owning FTQ entry
        /* Since multiple contiguous BTQ entries may be associated with an FTQ entry,
        an FTQ entry cannot dequeue until the "last" in the BTQ entry span is reached.

        TODO by retire coalescer unit (RCU):
        When a BTQ entry is dequeued, it spends 1 cycle to form into an FTB entry,
        and the FTB entry is latched into a "previous flop" local to the RCU.
        (maybe call prev-flop "working entry")

        For each new BTQ retiree entering the RCU:
        1. If prev-flop is invalid (i.e. contains no valid insn)
        -> Merge update into the FTQ-stored FTB entry copy, latch into prev-flop.
        2. Else if prev-flop valid && ftq_idx NOT match that of prev-flop.
        -> Push prev-flop entry to the FTB and dequeue its FTQ entry.
        -> Merge update into the FTQ-stored FTB entry copy, latch into prev-flop.
        3. Else if prev-flop valid && ftq_idx match that of prev-flop && !spill.
            (spill := the tail slot of the FTB entry, either from FTQ or prev-flop,
            is valid and the incoming retiree's branch's pc exceeds the tail slot's pc,
            requiring storage in the next FTB entry)
        -> Merge update into the prev-flop stored FTB entry copy.
        (no updates to FTB / dequeue from FTQ)
        4. Else if prev-flop valid && ftq_idx match that of prev-flop && spill.
        -> Push prev-flop entry to the FTB. (but DO NOT dequeue its FTQ entry)
        -> Advance retiree's fb_base past end of current FB and store into the prev-flop.
        (This can allow arbitrary chaining of spills, even if the FTB entry is packed
        with 16 branches. Each branch in the same 16-insn span with the same FB base
        will have the same ftq_idx. Each spill from the prev-flop will just push
        out the prev-flop and the new retiree will advance the FB base).
        */
} _BTQ_ENTRY;

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
        WADDR       base;
        FTB_ENTRY   fb;
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
        
        loc = locate(hdr, i_upd.base);

        s1w_n = '{
            en  : i_upd.en,
            sid : loc.sid,
            tag : loc.tag,
            way : ways[loc.sid],
            dat : i_upd.fb
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
            tgt_n[s1w.sid][s1w.way]     = i_upd.fb;
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
