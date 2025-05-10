`include "sys_defs.svh"

module btb #(parameter
    NUM_LINES=256
) (
    input clock,
    input reset,

    // query (fetch)
    input   fetch2btb   f_in,
    output  btb2fetch   f_out,

    // write (retire)
    input   puq2btb     puq_in
);
    localparam ASSOC = 2;
    localparam NUM_SETS = NUM_LINES / ASSOC;

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

    function automatic TAG get_tag(input WADDR waddr);
        return waddr[SID_BITS+TAG_BITS-1:SID_BITS];
    endfunction
    function automatic SID get_sid(input WADDR waddr);
        return waddr[SID_BITS-1:0];
    endfunction

    typedef struct packed {
        logic   [NUM_SETS-1:0][ASSOC-1:0] vld;
        TAG     [NUM_SETS-1:0][ASSOC-1:0] tag;
        logic   [NUM_SETS-1:0] lru; // 1 bit is enough for 2-way
    } HEADER;
    HEADER hdr, hdr_n;
    WADDR [NUM_SETS-1:0][ASSOC-1:0] tgt, tgt_n;

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

    always_comb begin
        hdr_n = hdr;
        tgt_n = tgt;

        // fetch
        f_out = '0;
        foreach (f_in.pc[i]) begin
            LOC loc;
            loc = locate(hdr, f_in.pc[i]);
            f_out.vld[i] = loc.hit;
            f_out.tgt[i] = tgt[loc.sid][loc.way];

            /* Unsure: btb reads during fetch should not update
            lru, since they're speculative right? */
            // if (f_in.en[i] && loc.hit)
            //     hdr_n.lru[loc.sid] = !loc.way;
        end

        // retire
        if (puq_in.en) begin
            LOC loc;

            loc = locate(hdr, puq_in.pc);
            if (!loc.hit) begin // dedup (dont insert if already there)
                WAY way;
                way = hdr.lru[loc.sid];

                hdr_n.vld[loc.sid][way] = 1;
                hdr_n.tag[loc.sid][way] = loc.tag;
                hdr_n.lru[loc.sid] = !way;
                tgt_n[loc.sid][way] = puq_in.tgt;
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            hdr <= '0;
            tgt <= '0;
        end else begin
            hdr <= hdr_n;
            tgt <= tgt_n;
        end
    end


`ifdef DEBUG
    task automatic print_btb();
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
