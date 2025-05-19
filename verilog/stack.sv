`include "sys_defs.svh"

module stack #(parameter
    DEPTH=2,
    WIDTH=1,
    RPORTS=1,
    WPORTS=1,
    ENABLE_INTR_FWD=`FALSE,
    type PTR = logic [$clog2(DEPTH)-1:0],
    type CNT = logic [$clog2(DEPTH):0]
) (
    input                                   clock, 
    input                                   reset,
    // >> TODO: handle
    input                                   flush,
    input   PTR                             flush_snap,
    input   BMASK                           clmsk,
    // << TODO: handle

    input   logic   [$clog2(WPORTS):0]      wr_en_cnt,
    input   logic   [WPORTS-1:0][WIDTH-1:0] wr_data,

    input   logic   [$clog2(RPORTS):0]      rd_en_cnt,
    output  logic   [RPORTS-1:0][WIDTH-1:0] rd_data,

    output  logic   [$clog2(WPORTS):0]      free_scnt,
    output  logic   [$clog2(RPORTS):0]      used_scnt
);
    function automatic CNT incr(input CNT p, input logic [$clog2(WPORTS):0] k);
        logic [$clog2(DEPTH+WPORTS):0] carry;
        carry = p + k;
        return (carry <= DEPTH) ? CNT'(carry) : CNT'(DEPTH);
    endfunction
    function automatic CNT decr(input CNT p, input unsigned k);
        return (k < p) ? p - k : 0;
    endfunction

    CNT top, free;
    PTR [RPORTS-1:0] rd_idxs;
    PTR [WPORTS-1:0] wr_idxs;
    logic [DEPTH-1:0][WIDTH-1:0] state;

    always_comb begin
        free = DEPTH - top;
        used_scnt = ENABLE_INTR_FWD
            ? `MIN(top + wr_en_cnt, RPORTS)
            : `MIN(top, RPORTS);
        free_scnt = `MIN(free, WPORTS);

        for (int i = 0; i < RPORTS; ++i)
            rd_idxs[i] = decr(top, i + 1); // +1: first read entry is 1 below top pointer
        for (int i = 0; i < WPORTS; ++i)
            wr_idxs[i] = incr(top, i);
    end

    always_comb begin
        for (int unsigned i = 0; i < RPORTS; ++i) begin
            if (i >= used_scnt)
                rd_data[i] = '0;
            else if ((i < wr_en_cnt) && ENABLE_INTR_FWD)
                rd_data[i] = wr_data[(wr_en_cnt-1) - i];
            else
                rd_data[i] = state[rd_idxs[
                    ENABLE_INTR_FWD
                        ? i - wr_en_cnt
                        : i
                ]];
        end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            top     <= '0;
            state   <= '0;
        end else begin
            top     <= wr_en_cnt >= rd_en_cnt
                ? incr(top, wr_en_cnt - rd_en_cnt)
                : decr(top, rd_en_cnt - wr_en_cnt);
            for (int i = 0; i < WPORTS; ++i) begin
                if (i >= wr_en_cnt) // suppresses oob index warning
                    break;
                state[wr_idxs[i]] <= wr_data[i];
            end
        end
    end
endmodule