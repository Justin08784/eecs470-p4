`include "sys_defs.svh"

/* TODO: Test lru_man, especially masking logic. */
module lru_man #(
    parameter SETW=16
) (
    input   logic [SETW-1:0] vld,
    input   logic [SETW-1:0][SETW-1:0] age,
    input   `IDX_TYPE(SETW) acc_way,   
    input   logic msk_en,
    input   `IDX_TYPE(SETW) msk_way,

    output  `IDX_TYPE(SETW) lru_way,
    output  logic [SETW-1:0][SETW-1:0] age_n
);
`define LRU_UTRI

`ifdef LRU_UTRI
/* interpret age as an "older than" upper triangle matrix:
age[i][j]
    1) is valid iff i < j
    2) if valid, means way i is "older" than way j */

    logic [SETW-1:0][SETW-1:0] vage, nvage; // valid age, ~(valid age)
    logic [SETW-1:0][SETW-1:0] ot, ot_masked;
    logic [SETW-1:0] lruv;
    generate
    for (genvar i = 0; i < SETW; ++i)
        assign vage[i] = vld[i] ? age[i] : '1; // empty lines are treated as "oldest" (all 1s)

    assign nvage = ~vage;
    for (genvar i = 0; i < SETW; ++i) begin
        for (genvar j = 0; j < SETW; ++j) begin
            assign ot[i][j] =
                i <  j ? vage[i][j] :
                i >  j ? nvage[j][i] :
                1;
        end
    end

    for (genvar i = 0; i < SETW; ++i) begin
        for (genvar j = 0; j < SETW; ++j) begin
            // force mask way to be youngest (protects it from LRU selection)
            assign ot_masked[i][j] =
                !msk_en         ? ot[i][j]  : 
                i == msk_way    ? 0         :
                j == msk_way    ? 1         :
                                  ot[i][j];
        end
    end

    for (genvar w = 0; w < SETW; ++w) begin
        assign lruv[w] = &ot_masked[w];
    end
    endgenerate

    always_comb begin
        lru_way = '0;
        for (int w = 0; w < SETW; ++w) begin
            if (lruv[w])
                lru_way = w;
        end
    end

    generate
    for (genvar i = 0; i < SETW; ++i) begin
        for (genvar j = i+1; j < SETW; ++j) begin
            assign age_n[i][j] =
                i == acc_way ? 0 :
                j == acc_way ? 1 :
                age[i][j];
        end

        for (genvar j = 0; j < i+1; ++j) begin
            assign age_n[i][j] = 1'b0;
        end
    end
    endgenerate

`else
/* interpret age as an "not younger than" full matrix:
age[i][j]
    1) is valid forall i, j
    2) means way i is "not younger" than way j */

    function automatic logic [SETW-1:0][SETW-1:0] update_lru(
        input logic [SETW-1:0][SETW-1:0] age,
        input `IDX_TYPE(SETW) way
    );
        logic [SETW-1:0][SETW-1:0] rv;
        rv = age;
        foreach(rv[i, j]) begin
            if (i == way)
                rv[i][j] = i == j;
            else if (j == way)
                rv[i][j] = 1;
        end
        return rv;
    endfunction

    logic [SETW-1:0] lru;
    generate
    for (genvar w = 0; w < SETW; ++w)
        assign lru[w] = &age[w];
    endgenerate

    always_comb begin
        lru_way = '0;
        for (int w = 0; w < SETW; ++w) begin
            if (lru[w])
                lru_way = w;
        end
    end

    assign age_n = update_lru(age, acc_way);
`endif

endmodule

// custom comparator for 4-bits. Seems to be faster than default synthesis of "<".
function automatic cmp4(
    input   logic [3:0] a,b,
    output  logic eq,
    output  logic lt
);
    logic [3:0] x;
    logic [3:0] l;
    logic eq_lo, eq_hi;
    logic lt_lo, lt_hi;

    x =  a   ^  b;
    l = (~a) &  b;

    eq_lo = ~(x[1] | x[0]);
    lt_lo = l[1] | (~x[1] & l[0]);

    eq_hi = ~(x[3] | x[2]);
    lt_hi = l[3] | (~x[3] & l[2]);

    eq = eq_hi & eq_lo;
    lt = lt_hi | (eq_hi & lt_lo);


    // logic [3:0] lt1, eq1;
    // logic [1:0] lt2, eq2;

    // for (int i = 0; i < 4; ++i) begin
    //     lt1[i] = !a[i] && b[i];
    //     eq1[i] =  a[i] == b[i];
    // end

    // lt2[0] = lt1[1] || (eq1[1] ? lt1[0] : 0);
    // lt2[1] = lt1[3] || (eq1[3] ? lt1[2] : 0);
    // eq2[0] = eq1[0] && eq1[1];
    // eq2[1] = eq1[2] && eq1[3];

    // eq = eq2[0] && eq2[1];
    // lt = lt2[1] || (eq2[1] ? lt2[0] : 0);
endfunction

module uftb #(
    parameter NUM_LINES=16
    // fully associative
) (
    input clock,
    input reset,

    // fetch query
    input   WADDR       i_qry, // branch pc

    output  logic       o_vld,
    output  FTB_ENTRY   o_tgt,

    // puq updates
    input   logic       i_uen,
    input   FTB_UPD_PKT i_udat
);
    localparam TAG_SKIMP = 0;
        /* TAG_SKIMP = how many bits to drop from the full tag that is required to
        eliminate aliases (0 for no alias).

        Increasing will result in more aliases, but acceptable for
        BTB since they are speculative. Can be worth to save area and logic. */
    localparam TAG_BITS = $bits(WADDR) - TAG_SKIMP;
    typedef logic [TAG_BITS-1:0]TAG;
    typedef `IDX_TYPE(NUM_LINES)WAY;
    typedef logic [NUM_LINES-1:0][NUM_LINES-1:0]AGE;

    function automatic TAG get_tag(input WADDR waddr);
        return waddr[TAG_BITS-1:0];
    endfunction

    typedef struct packed {
        logic   [NUM_LINES-1:0] dirty; // TODO: unused. use when doing multi-level FTB
        TAG     [NUM_LINES-1:0] tag;
        AGE     age;
            /* TODO:
            1. implement pLRU (tree or bit) for assoc ≥ 8.
            Maybe auto-switch between LRU and pRLU according to assoc
            parameter, keeping LRU for assoc < 8. 
            2. We can save bits in the LRU age matrix by storing the upper-triangle
            bits (top right above diagonal). */
    } HEADER;
    struct packed {
        logic   [NUM_LINES-1:0] vld;
    } hdr_ctl, hdr_ctl_n;
    HEADER hdr, hdr_n;
    FTB_ENTRY [NUM_LINES-1:0] tgt, tgt_n;

    typedef struct packed {
        logic   hit;
        WAY     way;
    } LOC;
    function automatic LOC locate(
        input HEADER    hdr,
        input TAG       tag
    );
        logic   [NUM_LINES-1:0] hitv;
        logic   hit;
        WAY     way;

        for (int w = 0; w < NUM_LINES; ++w)
            hitv[w] = hdr_ctl.vld[w] && (tag == hdr.tag[w]);

        hit = |hitv;
        way = 0;
        for (int w = 0; w < NUM_LINES; ++w) begin
            if (hitv[w])
                way = w;
        end

        return '{
            hit : hit,
            way : way
        };
    endfunction

    function automatic FTB_ENTRY wr_br0(
        input FTB_ENTRY     dst,
        input logic         always_take,
        input logic [1:0]   sc,
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        rv = dst;

        rv.br_slot[0] = '{
            sc  : sc,
            vld : 1,
            tgt : udat.tgt,
            off : udat.fb_off,
            always_take : always_take 
        };

        return rv;
    endfunction

    function automatic FTB_ENTRY wr_br1(
        input FTB_ENTRY     dst,
        input logic         always_take,
        input logic [1:0]   sc,
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        rv = dst;

        rv.br_slot[1] = '{
            sc  : sc,
            vld : 1,
            tgt : udat.tgt,
            off : udat.fb_off,
            always_take : always_take
        };

        rv.md1 = udat.md;

        return rv;
    endfunction

    function automatic FTB_ENTRY update_fb(
        output logic        hit_slot,
        output logic        spill,
        input FTB_ENTRY     dst,
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        logic [1:0] vld;
        logic eq0, eq1, lt0, gt1;
        logic hit0, hit1;

        logic [1:0] sc_new, // new slot sc
                    sc_upd0,// br0 sc updated
                    sc_upd1;// br1 sc updated
        logic at_new,
              at_upd0,
              at_upd1;

        sc_new  = WT;
            /* Q: Why not "udat.take ? WT : WN"? A:
            Only taken branches can insert a slot... in theory. */
        sc_upd0 = update_sc(dst.br_slot[0].sc, udat.take);
        sc_upd1 = update_sc(dst.br_slot[1].sc, udat.take);

        at_new  = 1;
        at_upd0 = udat.take && dst.br_slot[0].always_take; 
        at_upd1 = udat.take && dst.br_slot[1].always_take; 

        rv = dst;
        vld[0] = dst.br_slot[0].vld;
        vld[1] = dst.br_slot[1].vld;
        // eq0 = udat.fb_off == dst.br_slot[0].off;
        // lt0 = udat.fb_off <  dst.br_slot[0].off;
        // eq1 = udat.fb_off == dst.br_slot[1].off;
        // gt1 = udat.fb_off >  dst.br_slot[1].off;

        cmp4(udat.fb_off, dst.br_slot[0].off, eq0, lt0);
        cmp4(dst.br_slot[1].off, udat.fb_off, eq1, gt1);

        spill = vld[1] && gt1;
        hit0  = (vld[0] && eq0);
        hit1  = (vld[1] && eq1);
        hit_slot = hit0 || hit1;

        if (udat.md.cond) begin
            if (vld[0] && lt0) begin
                // shift left
                rv.br_slot[1]   = rv.br_slot[0];
                rv.md1.cond     = 1;
                rv = wr_br0(rv, at_new, sc_new, udat);

            end else begin
                /*
                improved critical path when this assignment was moved into `else`.
                knowledge injection: synthesizer does not know "shift left" and
                "wr_br1" are mutually exclusive (it is based upon the off0 < off1
                invariant)–– the programmer must make explicit what the synthesizer
                cannot infer.
                */

                rv = (
                    // (vld[1] &&   eq1)
                    hit1
                ||  (vld[0] && !(eq0 || lt0))
                )
                    ? wr_br1(
                        rv, 
                        hit1 ? at_upd1 : at_new,
                        hit1 ? sc_upd1 : sc_new,
                        udat
                    )

                    : wr_br0(
                        rv,
                        hit0 ? at_upd0 : at_new,
                        hit0 ? sc_upd0 : sc_new,
                        udat
                    );
            end 

        end else begin
            if (vld[0] && (eq0 || lt0)) begin
                // invalidate to ensure off[0] < off[1]
                rv.br_slot[0].vld = 0;
            end

            rv = wr_br1(
                rv, 
                hit1 ? at_upd1 : at_new,
                hit1 ? sc_upd1 : sc_new,
                udat
            );
        end

        // if (vld[0] && eq0)
        //     if (udat.md.cond)
        //         rv = wr_br0(rv, udat);
        //     else begin
        //         // invalidate to ensure off[0] < off[1]
        //         rv.br_slot[0].vld = 0;

        //         rv = wr_br1(rv, udat);
        //     end
        // else if (vld[1] && eq1)
        //     rv = wr_br1(rv, udat);
        // else
        //     if (!vld[0])
        //         rv = udat.md.cond
        //             ? wr_br0(rv, udat)
        //             : wr_br1(rv, udat);
        //     else
        //         if (lt0)
        //             if (udat.md.cond) begin
        //                 // shift left
        //                 rv.br_slot[1]   = rv.br_slot[0];
        //                 rv.md1.cond     = 1;

        //                 rv = wr_br0(rv, udat);
        //             end else begin
        //                 // invalidate to ensure off[0] < off[1]
        //                 rv.br_slot[0].vld = 0;

        //                 rv = wr_br1(rv, udat);
        //             end
        //         else
        //             rv = wr_br1(rv, udat);

        rv.end_off = rv.br_slot[1].vld
            ? rv.br_slot[1].off
            : 15;

        return rv;
    endfunction

    function automatic FTB_ENTRY create_fb(
        input FTB_UPD_PKT   udat
    );
        FTB_ENTRY rv;
        logic [1:0] sc_new;
        logic at_new;

        rv = '0;
        sc_new  = WT;
            /* Q: Why not "udat.take ? WT : WN"? A:
            Only taken branches can allocate an entry... in theory. */
        at_new  = 1;

        if (udat.md.cond) begin
            rv.end_off = 15;
            rv = wr_br0(rv, at_new, sc_new, udat);

        end else begin
            rv.end_off = udat.fb_off;
            rv = wr_br1(rv, at_new, sc_new, udat);

        end

        return rv;
    endfunction

    WAY lru_way, acc_way;
    AGE age_n;
    logic msk_en;
    WAY msk_way;
    lru_man #(
        .SETW(NUM_LINES)
    ) lru_man0 (
        .vld(hdr_ctl.vld),
        .age(hdr.age),

        .acc_way,
        .lru_way,

        .msk_en,
        .msk_way,

        .age_n
    );

    // fetch
    always_comb begin
        LOC loc;
        TAG tag;

        tag = get_tag(i_qry);
        loc = locate(hdr, tag);

        o_vld = loc.hit;
        o_tgt = tgt[loc.way];
    end

    // retire
    struct packed {
        logic   en;
    } s1_ctl, s1_ctl_n;
    struct packed {

        logic   hit;
        logic   hit_hdr;
        logic   hit_s1;
            /* Predecessor is valid and has matching tag.
            (When we reach s2, must bypass FTB_ENTRY from predecessor IFF it writes) */
        WAY     way;
        // logic   spill; // if we insert would we spill
            // ^^ FIXME unused

        FTB_ENTRY e;
        FTB_UPD_PKT udat;
    } s1, s1_n;
    struct packed {
        logic   wen; // did predecessor write at all?
    } s2_ctl, s2_ctl_n;
    struct packed {
        FTB_ENTRY e;
    } s2, s2_n;

    // s1
    always_comb begin
        TAG tag;
        LOC loc_s1, loc_hdr, loc;

        tag = get_tag(i_udat.base);
        // query s1 reg
        msk_en  = s1_ctl.en;
        msk_way = s1.way;
            // ^ protect our predecessor's way from LRU selection so we don't clobber it
        loc_s1  = '{
            hit : s1_ctl.en & (tag == get_tag(s1.udat.base)),
            way : s1.way
        };

        // query header
        loc_hdr = locate(hdr, tag);

        // mux loc, giving priority to s1 (bypass)
        loc.hit = loc_s1.hit | loc_hdr.hit;
        loc.way = '0;
        if (loc_s1.hit)
            loc.way = loc_s1.way;
        else
            loc.way = loc_hdr.way;

        s1_ctl_n= '{en  : i_uen};
        s1_n    = '{
            hit : loc.hit,
            hit_hdr : loc_hdr.hit,
            hit_s1  : loc_s1.hit,
            way : loc.hit ? loc.way : lru_way,

            e   : tgt[loc_hdr.way],
            udat: i_udat
        };
    end

    // s2
`ifdef FORMAL
    logic hit_slot_spill_mex;
`endif
    always_comb begin
        FTB_ENTRY wfb, upd_fb, new_fb, e;
        logic wen;

        logic spill;
        logic hit_slot; // does updatee already occupy a branch slot?
        logic alloc;    // entry miss, slot miss -> need allocate entry
        logic insert;   // entry hit , slot miss -> need allocate slot
        logic update;   // entry hit , slot hit
        logic augment;

        acc_way = s1.way;
        // e       = s1.e;
        e       = (s2_ctl.wen & s1.hit_s1) ? s2.e : s1.e;
            // bypass iff matching tag AND pred wrote
            // (if pred did not write, committed state is latest)
        upd_fb  = update_fb(hit_slot, spill, e, s1.udat);
        new_fb  = create_fb(s1.udat);
            /* NOTE: there IS a semantic difference between precomputing
            *_fb like this vs. putting them inline into the wfb ternary below.

            If you put it inline, then the arguments will execute ONLY IF the
            condition is evaluated. Of course, this is desirable for power,
            but undesirable for reduced critical path (???).

            (Q: How did I discover this fact? A: hit_slot_spill_mex was going
            X on cycles because hit_slot, spill were not being initialized on
            cycles, which is only possible if update_fb is conditinally executed.)
            */
        augment = (s2_ctl.wen & s1.hit_s1) | s1.hit_hdr;
        wfb     = augment ? upd_fb : new_fb;
`ifdef FORMAL
        hit_slot_spill_mex =
            ~augment                // filter non-applicable
        |   ~(hit_slot & spill);    // hit_slot and spill mutually exclusive?
`endif

        /* allocate-on-take policy:
        To conserve FTB space, a branch will never allocate/insert into the FTB
        until it is taken for the first time. This is in accordance with how
        Reinman et al. defines a "fetch block": an FB, unlike a basic block,
        may embed arbitrarily many "strongly biased not taken" branches. */
        alloc    = ~augment                 & s1.udat.take;
        insert   =  augment &   ~hit_slot   & s1.udat.take  & ~spill;
        update   =  augment &   hit_slot; // not taken branches can still update owned slots

        wen     = s1_ctl.en && (alloc || insert || update);
        // old: allocate-always policy
        // wen = s1.en && (!s1.hit || !spill);

        hdr_ctl_n = hdr_ctl;
        hdr_n = hdr;
        tgt_n = tgt;

        s2_ctl_n= '{wen : wen};
        s2_n    = '{e   : wfb};

        if (wen) begin
            hdr_ctl_n.vld[s1.way] = 1;
            hdr_n.dirty[s1.way] = 1;
            hdr_n.tag[s1.way]   = get_tag(s1.udat.base);
            hdr_n.age           = age_n;
                /* TODO: since every branch queries the FTB (but not every branch
                generates an FTB update) we need an LRU update for reads as well,
                not just writes. */

            tgt_n[s1.way]       = wfb;
        end

    end

    // single stage update
    // always_comb begin
    //     LOC loc;
    //     WAY way;
    //     logic spill;
    //     FTB_ENTRY wfb; // FTB entry with updates
    //     logic wen;

    //     loc = locate(hdr, i_udat.base);
    //     way = loc.hit ? loc.way : lru_way;
    //     acc_way = way;
    //     wfb = loc.hit
    //         ? update_fb(spill, tgt[loc.way], i_udat)
    //         : create_fb(i_udat);
    //     wen = i_uen && (!loc.hit || !spill);

    //     hdr_n = hdr;
    //     tgt_n = tgt;

    //     if (wen) begin
    //         hdr_n.vld[way]  = 1;
    //         hdr_n.dirty[way]= 1;
    //         hdr_n.tag[way]  = loc.tag;
    //         hdr_n.age       = age_n;
    //             /* TODO: since every branch queries the FTB (but not every branch
    //             generates an FTB update) we need an LRU update for reads as well,
    //             not just writes. */

    //         tgt_n[way]      = wfb;
    //     end
    // end

    always_ff @(posedge clock) begin
        if (reset) begin
            hdr_ctl <= '{vld: '0};
            s1_ctl  <= '{en : 0};
            s2_ctl  <= '{wen: 0};
        end else begin
            hdr_ctl <= hdr_ctl_n;
            s1_ctl  <= s1_ctl_n;
            s2_ctl  <= s2_ctl_n;
        end

        s1  <= s1_n;
        s2  <= s2_n;
        hdr <= hdr_n;
        tgt <= tgt_n;
    end


`ifdef FORMAL
    // runtime assertions
    always_ff @(posedge clock) begin
        if (!reset) begin
            assert(hit_slot_spill_mex) else $fatal("hit_slot and spill are both high: %b. en: %b, hit: %b, way: %b, e: %b, udat: %b",
            hit_slot_spill_mex,
            s1_ctl.en,
            s1.hit,
            s1.way,
            s1.e,
            s1.udat
            );
        end
    end
`endif


`ifdef DEBUG
    task automatic print_uftb();
        $display(">> uftb >>");
        // if (!reset) begin
        //     $display("s1: {en %b, hit: (%b, hdr: %b, s1: %b), way: %d} %b",
        //         s1_ctl.en,
        //         s1.hit,
        //         s1.hit_hdr,
        //         s1.hit_s1,
        //         s1.way,
        //         s1.e
        //     );

        //     $display("alloc: %b, insert: %b, update: %b",
        //         alloc,
        //         insert,
        //         update
        //     );

        //     $display("s2:{wen: %b} %b\n",
        //         s2_ctl.wen,
        //         s2.e
        //     );
        // end
        $display("i_uen: %b, {base: %d, fb_off: %d, take: %b, tgt: %d}",
            i_uen,
            i_udat.base,
            i_udat.fb_off,
            i_udat.take,
            i_udat.tgt
        );

        $display("s1_n: {en: %b, hit: %b, hit_s1: %b, way: %d} e:{}",
            s1_ctl_n.en,
            s1_n.hit,
            s1_n.hit_s1,
            s1_n.way);
        $display("[ {vld: %b, tgt: %d, off = %2d, always_take: %b},",
            s1_n.e.br_slot[0].vld,
            s1_n.e.br_slot[0].tgt,
            s1_n.e.br_slot[0].off,
            s1_n.e.br_slot[0].always_take
        );

        $display("  {vld: %b, tgt: %d, off = %2d, always_take: %b, ccrj: %b%b%b%b}]",
            s1_n.e.br_slot[1].vld,
            s1_n.e.br_slot[1].tgt,
            s1_n.e.br_slot[1].off,
            s1_n.e.br_slot[1].always_take,
            s1_n.e.md1.cond,
            s1_n.e.md1.call,
            s1_n.e.md1.ret,
            s1_n.e.md1.jalr
        );

        $display("s1: {en: %b, hit: %b, hit_s1: %b, way: %d} e:{}",
            s1_ctl.en,
            s1.hit,
            s1.hit_s1,
            s1.way);
        $display("[ {vld: %b, tgt: %d, off = %2d, always_take: %b},",
            s1.e.br_slot[0].vld,
            s1.e.br_slot[0].tgt,
            s1.e.br_slot[0].off,
            s1.e.br_slot[0].always_take
        );

        $display("  {vld: %b, tgt: %d, off = %2d, always_take: %b, ccrj: %b%b%b%b}]",
            s1.e.br_slot[1].vld,
            s1.e.br_slot[1].tgt,
            s1.e.br_slot[1].off,
            s1.e.br_slot[1].always_take,
            s1.e.md1.cond,
            s1.e.md1.call,
            s1.e.md1.ret,
            s1.e.md1.jalr
        );

        $display("s2_n: {wen: %b, e:{}",
            s2_ctl_n.wen
        );

        $display("[ {vld: %b, tgt: %d, off = %2d, always_take: %b},",
            s2_n.e.br_slot[0].vld,
            s2_n.e.br_slot[0].tgt,
            s2_n.e.br_slot[0].off,
            s2_n.e.br_slot[0].always_take
        );

        $display("  {vld: %b, tgt: %d, off = %2d, always_take: %b, ccrj: %b%b%b%b}]",
            s2_n.e.br_slot[1].vld,
            s2_n.e.br_slot[1].tgt,
            s2_n.e.br_slot[1].off,
            s2_n.e.br_slot[1].always_take,
            s2_n.e.md1.cond,
            s2_n.e.md1.call,
            s2_n.e.md1.ret,
            s2_n.e.md1.jalr
        );

        $display("s2: {wen: %b, e:{}",
            s2_ctl.wen);

        $display("[ {vld: %b, tgt: %d, off = %2d, always_take: %b},",
            s2.e.br_slot[0].vld,
            s2.e.br_slot[0].tgt,
            s2.e.br_slot[0].off,
            s2.e.br_slot[0].always_take
        );

        $display("  {vld: %b, tgt: %d, off = %2d, always_take: %b, ccrj: %b%b%b%b}]",
            s2.e.br_slot[1].vld,
            s2.e.br_slot[1].tgt,
            s2.e.br_slot[1].off,
            s2.e.br_slot[1].always_take,
            s2.e.md1.cond,
            s2.e.md1.call,
            s2.e.md1.ret,
            s2.e.md1.jalr
        );

        for (int w = 0; w < NUM_LINES; ++w)
            // $display("age[%d]: %b", w, lru_man0.ot_masked[w]);
            $display("age[%d]: %b", w, hdr.age[w]);

        for (int w = 0; w < NUM_LINES; ++w) begin
            FTB_ENTRY fb;
            WADDR base;

            if (!hdr_ctl.vld[w]) begin
                $display("uftb[%1d]:", w);
                // $display("uftb[%1d]:\n\n", w);
                continue;
            end

            fb = tgt[w];
            base = hdr.tag[w];

            $display("uftb[%1d]: base: %d, dirty: %b",
                w,
                base,
                hdr.dirty[w]
            );

            if (fb.br_slot[0].vld)
                $display("[{off: %d(pc=%d), tgt: %d, always_take: %b, sc: %b},",
                    fb.br_slot[0].off,
                    base + fb.br_slot[0].off,
                    fb.br_slot[0].tgt,
                    fb.br_slot[0].always_take,
                    fb.br_slot[0].sc
                );
            else
                $display("[{},");

            if (fb.br_slot[1].vld)
                $display(" {off: %d(pc=%d), tgt: %d, always_take: %b, sc: %b, ccrj: %b%b%b%b},",
                    fb.br_slot[1].off,
                    base + fb.br_slot[1].off,
                    fb.br_slot[1].tgt,
                    fb.br_slot[1].always_take,
                    fb.br_slot[1].sc,
                    fb.md1.cond,
                    fb.md1.call,
                    fb.md1.ret,
                    fb.md1.jalr
                );
            else
                $display(" {},");

            $display("  end_off = %2d]", fb.end_off);
        end

        $display("<< uftb <<");
    endtask
`endif

endmodule
