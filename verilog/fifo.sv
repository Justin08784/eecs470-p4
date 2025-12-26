`include "sys_defs.svh"

module fifo #(
    parameter int DEPTH=8,            // num elements
    parameter int WIDTH=57,// num bits per element
    type FIFO_STATE = struct packed {
        logic [DEPTH-1:0][WIDTH-1:0]state;
        `IDX_TYPE(DEPTH) head, tail;
        `CNT_TYPE(DEPTH) used;
    },
    parameter int FLUSH_MODE=FIFO_FLUSH_RESET,
    parameter int NUM_RPORTS=4, // also cap for used_scnt
    parameter int NUM_WPORTS=4, // also cap for free_scnt

    /* UPDATE: Prevew has been made the default mode! The consumer may read as
    many as they wish from rd_data. If they consume some rd_data they are obliged to
    (but not mandated to) signal the number read/consumed via rd_en_cnt. This breaks
    the old comb. path from rd_en_cnt to rd_data.

    If ENABLE_READ_PREVIEW is set, the FIFO supports *previewing* entries at the head
    (e.g., for dependency checks or early reads), even when rd_en_cnt is less than NUM_RPORTS.

    Specifically:
    - Normally, rd_data returns only the entries being read this cycle (i.e., up to rd_en_cnt).
    - With read preview enabled, rd_data can expose up to NUM_RPORTS entries from the head,
    regardless of rd_en_cnt.
    - These previewed values are valid *only if* the corresponding slot index is < used count.

    Use case:
    - Allows downstream logic (e.g., dispatch or issue) to see upcoming instructions
    or operands *without* formally dequeuing them.
    - This will be used for the decode FIFO, which needs to broadcast number of insns
    that need output regs to dispatch, and then dispatch to actually decide how many
    insns to dispatch.
    */
    parameter logic ENABLE_INTR_FWD =`FALSE,
    /*
    If free list mode is disabled, flush behaves the same as reset.
    */
    parameter int INSTANCE_ID=-1,
    parameter logic RESET_SETS_STATE=`FALSE,
    parameter FIFO_STATE RESET_STATE='{default:0},
    type PTR = `IDX_TYPE(DEPTH)
) (
    input                                           clock, 
    input                                           reset,
    input                                           flush,
    input   PTR                                     flush_snap,
    input   BMASK                                   clmsk,

    input   `CNT_TYPE(NUM_WPORTS)                   wr_en_cnt,
    input   logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data,
    input   BMASK   [NUM_WPORTS-1:0]                wr_bmask,
    output  PTR                                     tail,
    output  PTR     [NUM_WPORTS:0]                  wr_idxs_n,

    input   `CNT_TYPE(NUM_RPORTS)                   rd_en_cnt,
    output  logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data,
    output  BMASK   [NUM_RPORTS-1:0]                rd_bmask,
    output  PTR                                     head,
    output  PTR     [NUM_RPORTS:0]                  rd_idxs_n,

    output  logic                                   empty,
    output  logic                                   full,
    output  `CNT_TYPE(NUM_WPORTS)                   free_scnt,
    output  `CNT_TYPE(NUM_RPORTS)                   used_scnt

    /*NOTE: By removing rd_valid, wr_valid, we force the caller to make sure
    the enabled cnts are correct. */
);
    logic [DEPTH-1:0][WIDTH-1:0]    state;
    BMASK [DEPTH-1:0]               bmask;
    `CNT_TYPE(DEPTH) used, free;

    ring_ctr #(
        .DEPTH(DEPTH),
        .RPORTS(NUM_RPORTS),
        .WPORTS(NUM_WPORTS),
        .FLUSH_MODE(FLUSH_MODE),
        .INSTANCE_ID(INSTANCE_ID),
        .RESET_STATE('{
            head : RESET_STATE.head,
            tail : RESET_STATE.tail,
            used : RESET_STATE.used
        })
    ) ring_ctr0 (
        .clock,
        .reset,
        .flush,
        .flush_snap,

        .rd_en_cnt,
        .wr_en_cnt,

        .head,
        .tail,
        .rd_idxs_n,
        .wr_idxs_n,

        .used,
        .free,
        .used_scnt(), // DO NOT wire. Will compute this ourselves.
        .free_scnt

    );

    assign used_scnt    = ENABLE_INTR_FWD 
        ? `MIN(used + wr_en_cnt, NUM_RPORTS)
        : `MIN(used, NUM_RPORTS);
    assign empty        = used == 0;
    assign full         = used == DEPTH;

    logic [NUM_RPORTS-1:0] fwd_dat;
    always_comb begin
        for (int i = 0; i < NUM_RPORTS; ++i)
            fwd_dat[i] = i >= used && ENABLE_INTR_FWD;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i) begin
            if (i >= used_scnt) begin
                rd_data[i] = '0;
                rd_bmask[i] = '0;
            end else if (fwd_dat[i] && (i - used) < wr_en_cnt) begin // fwding logic
                rd_data[i] = wr_data[i - used];
                rd_bmask[i] = wr_bmask[i - used]; // does this need ~clmsk?
            end else begin
                rd_data[i] = state[rd_idxs_n[i]];
                rd_bmask[i] = bmask[rd_idxs_n[i]] & ~clmsk;
            end
        end
    end

    always_ff @(posedge clock) begin
        for (int i = 0; i < DEPTH; ++i)
            bmask[i] <= bmask[i] & ~clmsk;

        for (int unsigned i = 0; i < NUM_WPORTS; ++i) begin
            if (i >= wr_en_cnt) // suppresses oob index warning
                continue;
            state[wr_idxs_n[i]] <= wr_data[i];
            bmask[wr_idxs_n[i]] <= wr_bmask[i];
        end

        if (reset && RESET_SETS_STATE)
            state <= RESET_STATE.state;
    end

`ifdef FORMAL
    // runtime assertions
    always_ff @(posedge clock) begin
        if (!reset) begin

            int unsigned free_full, used_full;
            int unsigned rd_en_cnt_full, wr_en_cnt_full;
            free_full = free;
            used_full = used;
            rd_en_cnt_full = rd_en_cnt;
            wr_en_cnt_full = wr_en_cnt;
                /* ^^ Cast to full 32-bit temporaries for arithmetic.
                Q: Why? A: When you do arithmetic between, e.g. a + b, the result
                seems to have the type of the larger operand.

                And so if we just use the default, narrow types it is easy
                to overflow the result type in the arithmetic of the below assertions
                (e.g. free_full + rd_en_cnt_full). */

            if (wr_en_cnt > free_full + rd_en_cnt_full)
                $error("FIFO overflow! instance: %d (wr: %d, free: %d, rd: %d)",
                    INSTANCE_ID,
                    wr_en_cnt,
                    free,
                    rd_en_cnt
                );

            if (rd_en_cnt > used_full + wr_en_cnt_full)
                $error("FIFO underflow! instance: %d (rd: %d, used: %d, wr: %d)",
                    INSTANCE_ID,
                    rd_en_cnt,
                    used,
                    wr_en_cnt
                );

        end
    end
`endif

endmodule

// (only FIFO_FLUSH_RESET mode supported)
module fifo_barrel #(
    parameter int DEPTH =8,
    parameter int WIDTH =57,
    parameter int RPORTS=4,
    parameter int WPORTS=4
) (
    input   logic   clock,
    input   logic   reset,
    input   logic   flush,

    output  logic   [$clog2(RPORTS+1)-1:0]  rvld_cnt,
    input   logic   [$clog2(RPORTS+1)-1:0]  rrdy_cnt,
    // output  logic   [0:RPORTS-1]            rvld,   // used
    // input   logic   [0:RPORTS-1]            rrdy,
    output  logic   [0:RPORTS-1][0:WIDTH-1] rdat,

    input   logic   [$clog2(WPORTS+1)-1:0]  wvld_cnt,
    output  logic   [$clog2(WPORTS+1)-1:0]  wrdy_cnt,
    // input   logic   [0:WPORTS-1]            wvld,
    // output  logic   [0:WPORTS-1]            wrdy,   // free
    input   logic   [0:WPORTS-1][0:WIDTH-1] wdat

);

    initial begin
        // These should all be powers of 2
        assert  ((DEPTH != 0)   & ((DEPTH   & (DEPTH-1))    == 0)) else $fatal;
        // assert  ((WIDTH != 0)   & ((WIDTH   & (WIDTH-1))    == 0)) else $fatal;
        assert  ((RPORTS != 0)  & ((RPORTS  & (RPORTS-1))   == 0)) else $fatal;
        assert  ((WPORTS != 0)  & ((WPORTS  & (WPORTS-1))   == 0)) else $fatal;

        assert  (RPORTS <= DEPTH) else $fatal;
        assert  (WPORTS <= DEPTH) else $fatal;

    end
    typedef logic [DEPTH-1:0][$clog2((DEPTH-1)*WIDTH+1)-1:0] shift_rom_t;
    function automatic shift_rom_t gen_shift_rom();
        shift_rom_t rv;
        for (int unsigned i = 0; i < DEPTH; ++i)
            rv[i] = i * WIDTH;
        return rv;
    endfunction
    shift_rom_t shift_rom = gen_shift_rom(); // FIXME: if you make this a localparam area blows up for some reason????
    // initial begin
    //     $display("shift_rom");
    //     for (int i = 0; i < DEPTH; ++i)
    //         $display("[%1d]: %d", i, shift_rom[i]);
    // end

    logic [$clog2(DEPTH)-1:0]   head, head_n, tail, tail_n;
    logic [$clog2(DEPTH+1)-1:0] used, used_n, free;
    logic [DEPTH-1:0][WIDTH-1:0]state, state_n;

    assign free     = DEPTH - used;
    assign rvld_cnt = used < RPORTS ? used : RPORTS;
    assign wrdy_cnt = free < WPORTS ? free : WPORTS;

    logic[DEPTH-1:0][WIDTH-1:0] state_rotr;
    logic[2*DEPTH-1:0][WIDTH-1:0] state_dd;

    assign state_dd = {state, state};
    assign state_rotr= state_dd >> shift_rom[head];
    assign rdat = state_rotr[RPORTS-1:0];

    logic   [$clog2(RPORTS+1)-1:0]  ren_cnt;
    logic   [$clog2(WPORTS+1)-1:0]  wen_cnt;
    assign ren_cnt = rrdy_cnt < used ? rrdy_cnt : used;
    assign wen_cnt = free < wvld_cnt ? free : wvld_cnt;

    localparam DIFF         = DEPTH - WPORTS;
    localparam DIFF_WIDTHS  = (DEPTH - WPORTS) * WIDTH;
    logic[DEPTH-1:0][WIDTH-1:0] wdat_rotl;
    logic[2*DEPTH-1:0][WIDTH-1:0] wdat_dd, wdat_rotl_dd;
    assign wdat_dd = {{DIFF_WIDTHS{1'bx}}, wdat, {DIFF_WIDTHS{1'bx}}, wdat};
    assign wdat_rotl_dd = wdat_dd << shift_rom[tail];
    assign wdat_rotl = wdat_rotl_dd[2*DEPTH-1:DEPTH];

    logic[WPORTS-1:0] wen;
    logic[2*DEPTH-1:0] wmsk_rotl_dd;
    for (genvar i = 0; i < WPORTS; ++i)
        assign wen[i] = i < wen_cnt;
    assign wmsk_rotl_dd = {{DIFF{1'b0}}, wen, {DIFF{1'b0}}, wen} << tail;
    logic[DEPTH-1:0] wmsk_rotl;
    assign wmsk_rotl = wmsk_rotl_dd[2*DEPTH-1:DEPTH];

    assign head_n = head + ren_cnt;
    assign tail_n = tail + wen_cnt;
    assign used_n = (used + wen_cnt) - ren_cnt;
    for (genvar i = 0; i < DEPTH; ++i)
        assign state_n[i] = wmsk_rotl[i] ? wdat_rotl[i] : state[i];

    always_ff @(posedge clock) begin
        state   <= state_n;
        head    <= head_n;
        tail    <= tail_n;
        used    <= used_n;

        if (reset | flush) begin
            head <= '0;
            tail <= '0;
            used <= '0;
        end

    end

endmodule
