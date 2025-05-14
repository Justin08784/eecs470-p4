// pointer engine for fifos/ring buffers. no data storage
module ring_ptr #(
    parameter int DEPTH=2,
    parameter int WIDTH=1,
    parameter int RPORTS=1,
    parameter int WPORTS=1,
    parameter int FLUSH_MODE=RING_FLUSH_RESET,
    type PTR = logic [$clog2(DEPTH)-1:0],
    type CNT = logic [$clog2(DEPTH):0],
    type RING_PTR_STATE = struct packed {
        PTR head;
        PTR tail;
        CNT used;
    },
    parameter int INSTANCE_ID=-1,
    parameter RING_PTR_STATE RESET_STATE='{default:0}
) (
    input   clock,
    input   reset,
    input   flush,
    input   PTR     flush_tail,

    input   logic   [$clog2(RPORTS):0]  rd_en_cnt,
    input   logic   [$clog2(WPORTS):0]  wr_en_cnt,

    output  PTR     head,
    output  PTR     tail,
    output  logic   [RPORTS-1:0]        rd_idxs,
    output  logic   [WPORTS-1:0]        wr_idxs,

    output  CNT     used,
    output  CNT     free,
    output  logic   [$clog2(RPORTS):0]  used_scnt,
    output  logic   [$clog2(WPORTS):0]  free_scnt
);
    function automatic PTR incr(input PTR p, input int unsigned k);
        logic [$clog2(DEPTH):0] carry;
        carry = p + k;
        return (carry >= DEPTH) ? carry - DEPTH : carry[$bits(PTR)-1:0];
    endfunction
    function automatic PTR distance(input PTR x, input PTR y);
        return (y >= x) ? (y - x) : (y + DEPTH - x);
    endfunction

    always_comb begin
        free = DEPTH - used;

        used_scnt = `MIN(used, RPORTS);
        free_scnt = `MIN(free, WPORTS);

        for (int i = 0; i < RPORTS; ++i)
            rd_idxs[i] = incr(head, i);
        for (int i = 0; i < WPORTS; ++i)
            wr_idxs[i] = incr(tail, i);
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            used <= RESET_STATE.used;
            head <= RESET_STATE.head;
            tail <= RESET_STATE.tail;

        end else if (flush) begin
            unique case (FLUSH_MODE)
            RING_FLUSH_HEAD: begin
                used <= DEPTH;
                tail <= head;
            end

            RING_FLUSH_CHECK: begin
                used <= used - distance(flush_tail, tail);
                tail <= flush_tail;
            end

            default: begin
                used <= RESET_STATE.used;
                head <= RESET_STATE.head;
                tail <= RESET_STATE.tail;
            end
            endcase

        end else begin
            used <= used + wr_en_cnt - rd_en_cnt;
            head <= incr(head, rd_en_cnt);
            tail <= incr(tail, wr_en_cnt);

        end
    end

endmodule