`include "sys_defs.svh"

module ras #(
    parameter DEPTH = RAS_SZ,
    type PTR = `IDX_TYPE(DEPTH),
    type CNT = `CNT_TYPE(DEPTH)
) (
    input           clock, 
    input           reset,
    input           flush,
    input   BMASK   clmsk,

    // fetch
    output  RAS_SNAP if_snap_pre,
    output  RAS_SNAP if_snap_pos,
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

        ridx    = top - `UCAST_FIT(1); // wraparound is intended (likewise for write)
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
            used_n = full ? DEPTH : used + `UCAST_FIT(1);
            top_n  = top + `UCAST_FIT(1);
        end else if (ren) begin
            used_n = empty ? 0 : used - `UCAST_FIT(1);
            top_n  = ridx;
        end

        if_snap_pre = '{
            top : top,
            used: used
        };
        if_snap_pos = '{
            top : top_n,
            used: used_n
        };
    end

    always_ff @(posedge clock) begin
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


`ifdef FORMAL
    always_ff @(posedge clock) begin
        if (!reset) begin
            // CHECK: we accept at most 1 predict taken per cycle, so ren, wen must be exclusive
            assert(reset || !(wen & ren)) else $error("RAS: both wen and ren asserted");
        end
    end
`endif


`ifdef DEBUG
    task print_ras;
        logic [DEPTH-1:0] ras_vld;

        ras_vld = '0;
        for (int cnt = 0; cnt < used; ++cnt)
            ras_vld[(top - (cnt + 1)) % ROB_SZ] = 1;

        $display(">> RAS >>");
        // $display("used_n: %2d, top_n: %2d, full: %b, empty: %b", used_n, top_n, full, empty);
        // $display("ras: clock: %b, reset: %b, flush: %b, clmsk: %b, ren: %b, wen: %b, wtgt: %x, snap_in: %x",
        // clock,
        // reset,
        // flush,
        // clmsk,
        // ren,
        // wen,
        // wtgt,
        // snap_in
        // );
        $display("top: %2d, used: %2d", top, used);
        for (int i = 0; i < DEPTH; ++i) begin
            if (!ras_vld[i]) begin
                $display("ras[%2d]:", i);
                continue;
            end

            $display("ras[%2d]: %x", i, state[i]);
        end

        $display("");
        for (int i = 0; i < BMASK_LEN; ++i) begin
            RAS_SNAP snap;
            snap = snaps.snaps[i];
            $display("snaps[%8b]: top: %2d, used: %2d", 1 << i, snap.top, snap.used);
        end

        $display("<< RAS <<");
    endtask

`endif

endmodule