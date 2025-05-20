`include "sys_defs.svh"

module ras #(parameter
    DEPTH=2,
    type PTR = logic [$clog2(DEPTH)-1:0],
    type CNT = logic [$clog2(DEPTH):0]
) (
    input           clock, 
    input           reset,
    input           flush,
    input struct packed {
        PTR top;
        CNT used;
    } flush_snap,

    // fetch return
    output  WADDR   rtgt,
    input           ren,

    // fetch call
    input           wen,
    input   WADDR   wtgt,

    output  logic   full,
    output  logic   empty
);
    PTR top;
    CNT used;
    WADDR state [DEPTH-1:0];
    PTR ridx;

    always_comb begin
        full    = used == DEPTH;
        empty   = used == 0;

        ridx    = top - 1; // wraparound is intended (likewise for write)
        rtgt    = state[ridx];
    end

    always_ff @(posedge clock) begin
        // CHECK: we accept at most 1 predict taken per cycle, so ren, wen must be exclusive
        assert(!(wen & ren)) else $error("RAS: both wen and ren asserted");
        if (reset) begin
            used <= '0;
            top  <= '0;
            for (int i = 0; i < DEPTH; ++i)
                state[i] <= '0;
        end else if (flush) begin
            top  <= flush_snap.top;
            used <= flush_snap.used;
                /*
                FIXME: Do fifo snapshots need to store used count as well?
                e.g. What if a pointer needs to rollback more than "DEPTH" entries?
                (wouldn't the distance function would be wrong then?)
                */
        end else begin
            if (wen) begin
                used <= full ? DEPTH : used + 1;
                top  <= top + 1;
                state[top] <= wtgt;
            end else if (ren) begin
                used <= empty ? 0 : used - 1;
                top  <= ridx;
            end
        end
    end
endmodule