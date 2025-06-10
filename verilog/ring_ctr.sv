`include "sys_defs.svh"

// pointer engine for fifos/ring buffers. no data storage
module ring_ctr #(
    parameter int DEPTH=2,
    parameter int WIDTH=1,
    parameter int RPORTS=1,
    parameter int WPORTS=1,
    parameter int FLUSH_MODE=FIFO_FLUSH_RESET,
    type PTR = `IDX_TYPE(DEPTH),
    type CNT = `CNT_TYPE(DEPTH),
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

    input   `CNT_TYPE(RPORTS) rd_en_cnt,
    input   `CNT_TYPE(WPORTS) wr_en_cnt,

    output  PTR     head,
    output  PTR     tail,
    output  PTR     [RPORTS:0]          rd_idxs_n,
    output  PTR     [WPORTS:0]          wr_idxs_n,

    output  CNT     used,
    output  CNT     free,
    output  `CNT_TYPE(RPORTS) used_scnt,
    output  `CNT_TYPE(WPORTS) free_scnt
);
    function automatic PTR incr(input PTR p, input int unsigned k);
        logic [(`CNT_SIZE(DEPTH)+1)-1:0] carry;
        carry = p + k;
        return (carry >= DEPTH) ? carry - DEPTH : carry[$bits(PTR)-1:0];
    endfunction
    function automatic CNT distance(input PTR x, input PTR y);
        return (y >= x) ? (y - x) : (y + DEPTH - x);
    endfunction

    always_comb begin
        free = DEPTH - used;

        used_scnt = `MIN(used, RPORTS);
        free_scnt = `MIN(free, WPORTS);

        for (int i = 0; i < RPORTS+1; ++i)
            rd_idxs_n[i] = incr(head, i);
        for (int i = 0; i < WPORTS+1; ++i)
            wr_idxs_n[i] = incr(tail, i);
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
            head <= RESET_STATE.head;
            tail <= RESET_STATE.tail;

        end else if (flush) begin
            unique case (FLUSH_MODE)
            FIFO_FLUSH_SNAP_HEAD: begin
                used <= used + distance(flush_snap, head) + wr_en_cnt;
                head <= flush_snap;
                tail <= wr_idxs_n[wr_en_cnt];
            end

            FIFO_FLUSH_SNAP_TAIL: begin
                used <= used - distance(flush_snap, tail) - rd_en_cnt;
                head <= rd_idxs_n[rd_en_cnt];
                tail <= flush_snap;
            end

            default: begin
                used <= RESET_STATE.used;
                head <= RESET_STATE.head;
                tail <= RESET_STATE.tail;
            end
            endcase

        end else begin
            used <= used + wr_en_cnt - rd_en_cnt;
            head <= rd_idxs_n[rd_en_cnt];
            tail <= wr_idxs_n[wr_en_cnt];

        end
    end

endmodule