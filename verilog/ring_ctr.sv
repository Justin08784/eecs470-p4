// pointer engine for fifos/ring buffers. no data storage
module ring_ctr #(
    parameter int DEPTH=2,
    parameter int WIDTH=1,
    parameter int RPORTS=1,
    parameter int WPORTS=1,
    parameter int FLUSH_MODE=FIFO_FLUSH_RESET,
    type PTR = logic [$clog2(DEPTH)-1:0],
    type VEC = logic [DEPTH-1:0], // 1 hot vector pointer
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
    input   PTR     flush_snap,

    input   logic   [$clog2(RPORTS):0]  rd_en_cnt,
    input   logic   [$clog2(WPORTS):0]  wr_en_cnt,

    output  VEC     head,
    output  VEC     tail,
    output  PTR     [RPORTS:0]          rd_idxs_n,
    output  PTR     [WPORTS:0]          wr_idxs_n,

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
    function automatic CNT distance(input PTR x, input PTR y);
        return (y >= x) ? (y - x) : (y + DEPTH - x);
    endfunction

    PTR head_p, tail_p;

    function automatic PTR v2p (input VEC v);
        PTR p;
        p = 0;
        for (int i = 0; i < DEPTH; ++i)
            if (v[i])
                p = i;
        return p;
    endfunction
    function automatic VEC p2v (input PTR p);
        return 1 << p;
    endfunction

    function automatic VEC rotl(input VEC v, PTR sh);
        return (v << sh) | (v >> (DEPTH - sh));
    endfunction
    function automatic VEC rotr(input VEC v, PTR sh);
        return (v >> sh) | (v << (DEPTH - sh));
    endfunction

    always_comb begin
        free = DEPTH - used;

        used_scnt = `MIN(used, RPORTS);
        free_scnt = `MIN(free, WPORTS);

        for (int i = 0; i < RPORTS+1; ++i)
            rd_idxs_n[i] = head_p + i;
        for (int i = 0; i < WPORTS+1; ++i)
            wr_idxs_n[i] = tail_p + i;
    end

    // initial begin
    //     $display("id:%d, head: %d, tail: %d, used: %d",
    //     INSTANCE_ID,
    //     RESET_STATE.head,
    //     RESET_STATE.tail,
    //     RESET_STATE.used
    //     );
    // end

    always_ff @(posedge clock) begin
        if (reset) begin
            used <= RESET_STATE.used;
            head <= p2v(RESET_STATE.head);
            tail <= p2v(RESET_STATE.tail);
            head_p <= RESET_STATE.head;
            tail_p <= RESET_STATE.tail;

        end else if (flush) begin
            unique case (FLUSH_MODE)
            FIFO_FLUSH_SNAP_HEAD: begin
                used <= used + distance(flush_snap, head_p) + wr_en_cnt;
                head <= p2v(flush_snap);
                tail <= rotl(tail, wr_en_cnt);

                head_p <= flush_snap;
                tail_p <= tail_p + wr_en_cnt;
            end

            FIFO_FLUSH_SNAP_TAIL: begin
                used <= used - distance(flush_snap, tail_p) - rd_en_cnt;
                head <= rotl(head, rd_en_cnt);
                tail <= p2v(flush_snap);

                head_p <= head_p + rd_en_cnt;
                tail_p <= flush_snap;
            end

            default: begin
                used <= RESET_STATE.used;
                head <= p2v(RESET_STATE.head);
                tail <= p2v(RESET_STATE.tail);

                head_p <= RESET_STATE.head;
                tail_p <= RESET_STATE.tail;
            end
            endcase

        end else begin
            used <= used + wr_en_cnt - rd_en_cnt;
            head <= rotl(head, rd_en_cnt);
            tail <= rotl(tail, wr_en_cnt);

            head_p <= head_p + rd_en_cnt;
            tail_p <= tail_p + wr_en_cnt;
        end
    end

endmodule