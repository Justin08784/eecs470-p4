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
    logic       [sz-1:0][sz-1:0]age;
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
    logic       [sz-1:0][sz-1:0]age;

    assign dbg = '{
        vld,
        tag,
        dat,
        age
    };

    logic [sz-1:0] rmsk;
    always_comb begin
        rmsk = '0;
        rdat = '0;
        foreach(tag[i]) begin
            if (ren && vld[i] && tag[i] == get_dwaddr(raddr)) begin
                rmsk[i] |= 1;
                rdat    |= dat[i];
            end
        end
        rvld = |rmsk;
    end

    logic [sz-1:0] free_gnt;
    psel_gen #(
        .WIDTH(sz),
        .REQS(1)
    ) free_arb (
        .req(~vld),
        .gnt(free_gnt)
    );

    logic [sz-1:0] wmsk;
    always_comb begin
        /* WARNING: free_gnt is a bit vector */
        wmsk = |free_gnt
            ? free_gnt      // free entry available
            : age[sz-1:0];  // evict a block
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            vld <= '0;
            tag <= '0;
            dat <= '0;
            age <= '0;
        end else begin
            if (rvld) begin
                vld[rmsk] <= 0;
                tag[rmsk] <= '0;
                dat[rmsk] <= '0;
                age[rmsk] <= '0;
            end
            $display("wmsk: %b", wmsk);

            if (wen) begin
                foreach(wmsk[i]) begin
                    if (wmsk[i]) begin
                        vld[i] <= 1;
                        tag[i] <= get_dwaddr(waddr);
                        dat[i] <= wdat;
                        age[i] <= 1;
                    end else begin
                        age[i] <= age[i] << 1;
                    end
                end
            end
        end
    end
endmodule