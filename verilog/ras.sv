`include "sys_defs.svh"

module ras #(
    parameter DEPTH = `RAS_SZ,
    type PTR = logic [$clog2(DEPTH)-1:0],
    type CNT = logic [$clog2(DEPTH):0]
) (
    input           clock, 
    input           reset,
    input           flush,
    input   BMASK   clmsk,

    // fetch
    output  RAS_SNAP if_snap,
        // return
    output  WADDR   rtgt,
    input           ren,
        // call
    input           wen,
    input   WADDR   wtgt,

    // dispatch (alloc snapshot)
    input  rename2snap_bus snap_in,

    output  logic   full,
    output  logic   empty
);
    RAS_SNAP snap;
        /* FIXME: Do fifo snapshots need to store used count as well?
        e.g. What if a pointer needs to rollback more than "DEPTH" entries?
        (wouldn't the distance function would be wrong then?) */
    PTR top, top_n;
    CNT used, used_n;
    WADDR state [DEPTH-1:0];
    PTR ridx;

    always_comb begin
        full    = used == DEPTH;
        empty   = used == 0;

        ridx    = top - 1; // wraparound is intended (likewise for write)
        rtgt    = state[ridx];
    end

    general_snaps #(
        .WIDTH($bits(RAS_SNAP))
    ) snaps (
        .clock,

        .rmsk   (clmsk),
        .rdat   (snap),

        .wen    (snap_in.snap_en),
        .wmsk   (snap_in.b1hot_n),
        .wdat   (snap_in.ras_snap)
    );

    always_comb begin
        used_n = used;
        top_n  = top;
        if (flush) begin
            used_n = snap.used;
            top_n  = snap.top;
        end else if (wen) begin
            used_n = full ? DEPTH : used + 1;
            top_n  = top + 1;
        end else if (ren) begin
            used_n = empty ? 0 : used - 1;
            top_n  = ridx;
        end

        if_snap = '{
            top : top_n,
            used: used_n
        };
    end

    always_ff @(posedge clock) begin
        // CHECK: we accept at most 1 predict taken per cycle, so ren, wen must be exclusive
        assert(reset || !(wen & ren)) else $error("RAS: both wen and ren asserted");
        if (reset) begin
            used <= '0;
            top  <= '0;
            for (int i = 0; i < DEPTH; ++i)
                state[i] <= '0;
        end else begin
            used <= used_n;
            top  <= top_n;
            if (wen && !flush)
                state[top] <= wtgt;
        end
    end
endmodule