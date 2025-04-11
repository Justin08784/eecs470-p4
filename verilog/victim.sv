`include "sys_defs.svh"

/* Get double word address; restricting to only actually used 16 LSB. */
function automatic logic[12:0] get_dwaddr(input ADDR addr);
    return addr[15:3];
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
    logic       [sz-1:0][sz-1:0]age;    // age[i, j] := i is NOT younger than j

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
    logic [sz-1:0] lru;
    always_comb begin
        foreach (lru[i])
            lru[i] = &age[i];

        wmsk = |free_gnt
            ? free_gnt  // free entry available
            : lru;      // evict a block
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            vld <= '0;
            tag <= '0;
            dat <= '0;
            foreach (age[i, j])
                age[i][j] <= i == j;
        end else begin
            foreach (rmsk[i]) begin
                if (!rmsk[i])
                    continue;
                vld[i] <= 0;
                tag[i] <= '0;
                dat[i] <= '0;
                age[i] <= '0;
            end
            $display("wmsk: %b", wmsk);

            if (wen) begin
                foreach(wmsk[i]) begin
                    if (!wmsk[i])
                        continue;
                    vld[i] <= 1;
                    tag[i] <= get_dwaddr(waddr);
                    dat[i] <= wdat;
                end

                foreach(age[i, j]) begin
                    if (wmsk[i]) begin
                        age[i][j] <= i == j;
                    end else if (wmsk[j]) begin
                        age[i][j] <= 1;
                    end
                end
            end
        end
    end
endmodule