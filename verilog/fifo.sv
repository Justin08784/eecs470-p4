`include "sys_defs.svh"

module fifo #(
    parameter int DEPTH=`ROB_SZ,            // num elements
    parameter int WIDTH=$bits(PHYS_REG_IDX),// num bits per element
    type FIFO_STATE = struct packed {
        logic [$clog2(DEPTH)-1:0]   head;
        logic [$clog2(DEPTH)-1:0]   tail;
        logic [DEPTH-1:0][WIDTH-1:0]state;
        logic [$clog2(DEPTH):0]     used;
    },
    parameter int FLUSH_MODE=FIFO_FLUSH_RESET,
    parameter int NUM_RPORTS=`N, // also cap for used_scnt
    parameter int NUM_WPORTS=`N, // also cap for free_scnt

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
    parameter FIFO_STATE RESET_STATE='{default:0}
) (
    input                                           clock, 
    input                                           reset,
    input                                           flush,
    input   logic   [$clog2(DEPTH)-1:0]             flush_tail,

    input   logic   [$clog2(NUM_WPORTS):0]          wr_en_cnt,
    input   logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data,

    input   logic   [$clog2(NUM_RPORTS):0]          rd_en_cnt,
    output  logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data,

    output  logic                                   empty,
    output  logic                                   full,
    output  logic   [$clog2(NUM_WPORTS):0]          free_scnt,
    output  logic   [$clog2(NUM_RPORTS):0]          used_scnt

    /*NOTE: By removing rd_valid, wr_valid, we force the caller to make sure
    the enabled cnts are correct. */
);
    typedef logic [$clog2(DEPTH)-1:0] PTR;
    function automatic PTR incr(input PTR ptr, input int unsigned step);
        logic [$clog2(DEPTH):0] carry;
        carry = ptr + step;
        return (carry >= DEPTH) ? carry - DEPTH : carry[$bits(PTR)-1:0];
    endfunction
    function automatic PTR distance(input PTR x, input PTR y);
        return (y >= x) ? (y - x) : (y + DEPTH - x);
    endfunction

    logic [$clog2(DEPTH)-1:0]       head;
    logic [$clog2(DEPTH)-1:0]       tail;
    logic [DEPTH-1:0][WIDTH-1:0]    state;
    logic [$clog2(DEPTH):0]         used, free;

    logic [NUM_RPORTS-1:0][$clog2(DEPTH)-1:0] rd_idxs;
    logic [NUM_WPORTS-1:0][$clog2(DEPTH)-1:0] wr_idxs;

    assign free         = DEPTH - used;
    assign free_scnt    = `MIN(free, NUM_WPORTS);
    assign used_scnt    = ENABLE_INTR_FWD 
        ? `MIN(used + wr_en_cnt, NUM_RPORTS)
        : `MIN(used, NUM_RPORTS);
    assign empty        = used == 0;
    assign full         = used == DEPTH;

    logic [NUM_RPORTS-1:0] fwd_dat;
    always_comb begin
        for (int i = 0; i < NUM_RPORTS; ++i)
            rd_idxs[i] = incr(head, i);
        for (int i = 0; i < NUM_WPORTS; ++i)
            wr_idxs[i] = incr(tail, i);
        for (int i = 0; i < NUM_RPORTS; ++i)
            fwd_dat[i] = i >= used && ENABLE_INTR_FWD;

        for (int unsigned i = 0; i < NUM_RPORTS; ++i) begin
            if (i >= used_scnt) begin
                rd_data[i] = '0;
            end else if (fwd_dat[i] && (i - used) < wr_en_cnt) begin // fwding logic
                rd_data[i] = wr_data[i - used];
            end else begin
                rd_data[i] = state[rd_idxs[i]];
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            used    <= RESET_STATE.used;
            head    <= RESET_STATE.head;
            tail    <= RESET_STATE.tail;
            state   <= RESET_STATE.state;
        end else if (flush) begin
            unique case (FLUSH_MODE)
            FIFO_FLUSH_HEAD: begin
                used    <= DEPTH;
                tail    <= head;
            end

            FIFO_FLUSH_CHECK: begin
                used    <= used - distance(flush_tail, tail);
                tail    <= flush_tail;
            end

            default: begin
                used    <= RESET_STATE.used;
                head    <= RESET_STATE.head;
                tail    <= RESET_STATE.tail;
                state   <= RESET_STATE.state;
            end
            endcase
        end else begin
            if (wr_en_cnt > (ENABLE_INTR_FWD ? free + rd_en_cnt : free))
                $error("FIFO overflow! instance: %d", INSTANCE_ID);
            if (rd_en_cnt > (ENABLE_INTR_FWD ? used + wr_en_cnt : used))
                $error("FIFO underflow! instance: %d", INSTANCE_ID);
            used    <= used + wr_en_cnt - rd_en_cnt;
            head    <= incr(head, rd_en_cnt);
            tail    <= incr(tail, wr_en_cnt);
            for (int unsigned i = 0; i < NUM_WPORTS; ++i) begin
                if (i >= wr_en_cnt) // suppresses oob index warning
                    continue;
                state[wr_idxs[i]] <= wr_data[i];
            end
        end
    end
endmodule