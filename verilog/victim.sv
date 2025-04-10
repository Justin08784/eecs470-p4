`include "sys_defs.svh"

/* Get word address; restricting to only actually used 16 LSB. */
// function automatic WADDR get_waddr(input ADDR addr);
//     return addr[15:2];
// endfunction

function automatic logic[12:0] get_dwaddr(input ADDR addr);
    return addr[15:3];
endfunction

/* In-word offset */
function automatic logic[1:0] iw_off(input ADDR addr);
    return addr[1:0];
endfunction


localparam sz = 4;
typedef struct packed {
    logic       [sz-1:0]        vld;
    logic       [sz-1:0][15:3]  tag;
    MEM_BLOCK   [sz-1:0]        dat;
    logic       [sz-1:0][1:0]   prio;
} STATE;

module victim_cache (
    input logic clock,
    input logic reset,

    // evicted block
    input logic     wen,
    input ADDR      waddr,
    input DATA      wdat,

    input  logic    ren,
    input  ADDR     raddr,
    output DATA     rdat,
    output logic    rvld,

    output STATE    dbg
);
    logic       [sz-1:0]        vld;
    logic       [sz-1:0][15:3]  tag;
    MEM_BLOCK   [sz-1:0]        dat;
    logic       [sz-1:0][1:0]   prio;

    assign dbg = '{
        vld,
        tag,
        dat,
        prio
    };

    logic [$clog2(sz)-1:0]  ridx;
    always_comb begin
        ridx = '0;
        rvld = 0;
        rdat = '0;
        foreach(tag[i]) begin
            if (ren && vld[i] && (get_dwaddr(raddr) == tag[i])) begin
                ridx |= i;
                rvld |= 1;
                rdat |= dat[i];
            end
        end
    end

    logic [sz-1:0] free_gnt;
    psel_gen #(
        .WIDTH(sz),
        .REQS(1)
    ) free_arb (
        .req(~vld),
        .gnt(free_gnt)
    );

    logic [$clog2(sz)-1:0]  widx;
    logic [$clog2(sz)-1:0]  max_idx, max_val;
    always_comb begin
        widx = '0;
        max_idx = '0;
        max_val = '0;
        /* WARNING: free_gnt is a bit vector */
        if (free_gnt) begin
            // free entry available
            foreach (free_gnt[i]) begin
                if (!free_gnt[i])
                    continue;
                widx |= i;
            end

        end else begin
            // evict a block
            foreach (prio[i]) begin
                if (prio[i] <= max_val)
                    continue;
                max_idx = i;
                max_val = prio[i];
            end

            widx |= max_idx;

        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            vld <= '0;
            tag <= '0;
            dat <= '0;
            prio <= '0;
        end else begin
            if (rvld) begin
                vld[ridx] <= 0;
                tag[ridx] <= '0;
                dat[ridx] <= '0;
                prio[ridx] <= '0;
            end

            if (wen) begin
                vld[widx] <= 1;
                tag[widx] <= get_dwaddr(waddr);
                dat[widx] <= wdat;
                prio[widx] <= '0;

                // update prios
                foreach (vld[i]) begin
                    if (i == widx
                        || !prio[widx]
                        || &prio[i])    // prio is already at max 
                        continue;
                    prio[i] <= prio[i] + 1;
                end
            end
        end
    end
endmodule