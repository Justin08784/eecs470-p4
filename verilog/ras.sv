`include "sys_defs.svh"

module ras #(parameter
    DEPTH=2,
    type PTR = logic [$clog2(DEPTH)-1:0],
    type CNT = logic [$clog2(DEPTH):0]
) (
    input           clock, 
    input           reset,
    input           flush,
    input   CNT     flush_snap,

    // fetch return
    output  WADDR   rtgt,
    input           ren,

    // fetch call
    input           wen,
    input   WADDR   wtgt,

    output  logic   full,
    output  logic   empty
);
    CNT used;
    WADDR state [DEPTH-1:0];
    PTR ridx, widx;

    always_comb begin
        full    = used == DEPTH;
        empty   = used == 0;

        ridx    = (used == 0) ? 0 : used - 1;
        rtgt    = state[ridx];

        widx    = `MIN(used, DEPTH-1);
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            used <= '0;
            for (int i = 0; i < DEPTH; ++i)
                state[i] <= '0;
        end else if (flush) begin
            used <= flush_snap;
        end else begin
            used <= used + wen - ren;
            if (wen)
                state[widx] <= wtgt;
        end
    end
endmodule