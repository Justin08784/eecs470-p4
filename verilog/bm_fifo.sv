`include "sys_defs.svh"

module fifo #(
    parameter int unsigned DEPTH=`ROB_SZ,       // num elements
    parameter int unsigned WIDTH=$bits(PHYS_REG_IDX),       // num bits per element
    type FIFO_STATE = struct packed {
        logic [$clog2(DEPTH)-1:0] head;
        logic [$clog2(DEPTH)-1:0] tail;
        logic [DEPTH-1:0][WIDTH-1:0] state;
        logic [$clog2(DEPTH):0]   used;
        // logic [$clog2(DEPTH):0]   free;
    },
    parameter int unsigned NUM_RPORTS=`N, // also cap for used_scnt
    parameter int unsigned NUM_WPORTS=`N, // also cap for free_scnt

    /*
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
    parameter logic ENABLE_READ_PREVIEW=`FALSE,
    parameter logic ENABLE_INTR_FWD =`FALSE,
    parameter logic ENABLE_CUSTOM_RESET = `FALSE,
    parameter int   INSTANCE_ID=-1
) (
    input                                           clock, 

    input                                           reset,
    input   FIFO_STATE                              reset_state,

    input                                           flush,
    input   BMASK                                   bmask_mask,
    output  logic   [NUM_RPORTS-1:0]                rd_bm_vld,

    input   logic   [$clog2(NUM_WPORTS):0]          wr_en_cnt,
    input   logic   [NUM_WPORTS-1:0][WIDTH-1:0]     wr_data,

    input   logic   [$clog2(NUM_RPORTS):0]          rd_en_cnt,
    output  logic   [NUM_RPORTS-1:0][WIDTH-1:0]     rd_data,
    output  logic   [$clog2(NUM_RPORTS):0]          prvw_vld_cnt, // only valid if ENABLE_READ_PREVIEW set

    output  logic                                   empty,
    output  logic                                   full,
    output  logic   [$clog2(NUM_WPORTS):0]          free_scnt,
    output  logic   [$clog2(NUM_RPORTS):0]          used_scnt

    /*NOTE: By removing rd_valid, wr_valid, we force the caller to make sure
    the enabled cnts are correct. */
);
    typedef struct packed {
        logic vld;
        BMASK bmask;
    } BM_TAG;
    typedef struct packed {
        BM_TAG bm_tag;
        logic [(WIDTH-$bits(BM_TAG))-1:0] data;
    } TAGGED_ENTRY;

    logic [$clog2(DEPTH)-1:0]       head;
    logic [$clog2(DEPTH)-1:0]       tail;
    logic [DEPTH-1:0][WIDTH-1:0]    state;
    logic [$clog2(DEPTH):0]         used, free;
    logic [$clog2(NUM_RPORTS):0]    show_limit;   // how many entries we display in rd_data

    logic [NUM_RPORTS-1:0][$clog2(DEPTH)-1:0] rd_idxs;
    logic [NUM_WPORTS-1:0][$clog2(DEPTH)-1:0] wr_idxs;

    assign free         = DEPTH - used;
    assign free_scnt    = `MIN(free, NUM_WPORTS);
    assign used_scnt    = `MIN(used, NUM_RPORTS);
    assign empty        = used == 0;
    assign full         = used == DEPTH;
    assign prvw_vld_cnt = ENABLE_READ_PREVIEW
        ? `MIN(used + (ENABLE_INTR_FWD ? wr_en_cnt : 0), NUM_RPORTS)
        : '0;
    assign show_limit   = ENABLE_READ_PREVIEW ? prvw_vld_cnt : rd_en_cnt;

    // Version 1:
    // always_comb begin
    //     for (int unsigned i = 0; i < NUM_RPORTS; ++i)
    //         rd_idxs[i] = (head + i) % DEPTH;
    //     for (int unsigned i = 0; i < NUM_WPORTS; ++i)
    //         wr_idxs[i] = (tail + i) % DEPTH;


    //     rd_data = '0;
    //     // fwd if read matches a write; last write wins
    //     for (int unsigned i = 0; i < NUM_RPORTS; ++i) begin
    //         if (i >= rd_en_cnt) // suppresses oob index warning
    //             continue;
    //         rd_data[i] = state[rd_idxs[i]];
    //         for (int unsigned j = 0; j < NUM_WPORTS; ++j) begin
    //             if (j >= wr_en_cnt || rd_idxs[i] != wr_idxs[j]) // j >= ... suppresses oob index warning
    //                 continue;
    //             rd_data[i] = wr_data[j];
    //         end
    //     end
    // end

    // Version 2:
    logic [NUM_RPORTS-1:0] fwd_dat;
    TAGGED_ENTRY tmp;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            rd_idxs[i] = (head + i) % DEPTH;
        for (int unsigned i = 0; i < NUM_WPORTS; ++i)
            wr_idxs[i] = (tail + i) % DEPTH;
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            fwd_dat[i] = i >= used && ENABLE_INTR_FWD;

        // fwding logic
        for (int unsigned i = 0; i < NUM_RPORTS; ++i) begin
            if (i >= show_limit) begin
                rd_data[i] = '0;
            end else if (fwd_dat[i] && (i - used) < wr_en_cnt) begin
                rd_data[i] = wr_data[i - used];
                if (ENABLE_BMASK_INVALIDATION) begin
                    tmp = rd_data[i];
                    rd_bm_vld[i] = tmp.bm_tag.vld;
                end
            end else begin
                rd_data[i] = state[rd_idxs[i]];
                if (ENABLE_BMASK_INVALIDATION) begin
                    tmp = rd_data[i];
                    rd_bm_vld[i] = tmp.bm_tag.vld;
                end
            end
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            if (ENABLE_CUSTOM_RESET) begin
                used    <= reset_state.used;
                head    <= reset_state.head;
                tail    <= reset_state.tail;
                state   <= reset_state.state;
            end else begin
                used    <= '0;
                head    <= '0;
                tail    <= '0;
                state   <= '0;
            end
        end else if (flush && ENABLE_BMASK_INVALIDATION) begin
            /* assume lowest 5 bits is bm_valid */
            foreach (state[i]) begin
                tmp = state[i];
                if (!(tmp.bm_tag.bmask & bmask_mask))
                    continue;
                tmp.bm_tag.vld = 0;
                state[i] <= tmp;
            end
        end else begin
            if (wr_en_cnt > (ENABLE_INTR_FWD ? free + rd_en_cnt : free))
                $error("FIFO overflow! instance: %d", INSTANCE_ID);
            if (rd_en_cnt > (ENABLE_INTR_FWD ? used + wr_en_cnt : used))
                $error("FIFO underflow! instance: %d", INSTANCE_ID);
            used    <= used + wr_en_cnt - rd_en_cnt;
            head    <= (head + rd_en_cnt) % DEPTH;
            tail    <= (tail + wr_en_cnt) % DEPTH;
            for (int unsigned i = 0; i < NUM_WPORTS; ++i) begin
                if (i >= wr_en_cnt) // suppresses oob index warning
                    continue;
                // NOTE: writer should set the bm_tag
                state[wr_idxs[i]] <= wr_data[i];
            end
        end
    end
endmodule