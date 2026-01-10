`include "sys_defs.svh"

// pointer engine for fifos/ring buffers. no data storage
/* compute full rd, wr windows before end of each cycle to move it off of
read/write critical path (in theory). In the old impl, wr/rd_idxs_n
were computed combinationally at the START of cycle before reads/writes,
putting +1 adders on the critical path. */
module ring_ctr #(
    parameter int DEPTH=2,
    parameter int RPORTS=1,
    parameter int WPORTS=1,
    parameter int FLUSH_MODE=FIFO_FLUSH_RESET,
    // type PTR    = `PTR_TYPE (DEPTH),
    type DPTR   = `PTR_TYPE (2*DEPTH),
    type CNT    = `CNT_TYPE (DEPTH),
    type RING_PTR_STATE = struct packed {
        DPTR    head;
        DPTR    tail;
        CNT     used;
    },
    parameter int INSTANCE_ID=-1,
    parameter RING_PTR_STATE RESET_STATE='{default:0}
) (
    input   clock,
    input   reset,
    input   flush,
    input   DPTR    flush_snap,

    input   `CNT_TYPE(RPORTS) rd_en_cnt,
    input   `CNT_TYPE(WPORTS) wr_en_cnt,

    output  DPTR    head,
    output  DPTR    tail,
    output  DPTR    [RPORTS:0]          rd_idxs_n,
    output  DPTR    [WPORTS:0]          wr_idxs_n,

    output  CNT     used,
    output  CNT     free,
    output  `CNT_TYPE(RPORTS) used_scnt,
    output  `CNT_TYPE(WPORTS) free_scnt
);
    localparam int max_port_cnt = `MAX(RPORTS, WPORTS);
    typedef logic [max_port_cnt:0][$clog2(max_port_cnt*$bits(DPTR)+1)-1:0] shift_rom_t;
    function automatic shift_rom_t gen_shift_rom();
        shift_rom_t rv;
        for (int unsigned i = 0; i <= max_port_cnt; ++i)
            rv[i] = i * $bits(DPTR);
        return rv;
    endfunction
    localparam shift_rom_t shift_rom = gen_shift_rom();

    initial begin
        assert(RPORTS <= DEPTH) else $fatal;
        assert(WPORTS <= DEPTH) else $fatal;
        assert(`is_pow2(DEPTH)) else $fatal;
    end

    DPTR [RPORTS:0]     rd_win;
    DPTR [RPORTS-1:0]   rd_nex;
    DPTR [WPORTS:0]     wr_win;
    DPTR [WPORTS-1:0]   wr_nex;
    // casted constants
    localparam `CNT_TYPE(DEPTH) _DEPTH  = DEPTH;
    localparam `CNT_TYPE(RPORTS)_RPORTS = RPORTS;
    localparam `CNT_TYPE(WPORTS)_WPORTS = WPORTS;

    // function automatic PTR incr(input PTR p, input int unsigned k);
    //     logic [`CNT_SIZE(2*_DEPTH)-1:0] carry;
    //     carry = p + k;
    //     return (carry >= _DEPTH) ? carry - _DEPTH : carry;
    // endfunction
    function automatic CNT distance(input DPTR x, input DPTR y);
        return (y >= x) ? (y - x) : (y + _DEPTH - x);
    endfunction

    assign head     = rd_win[0];
    assign tail     = wr_win[0];
    assign rd_idxs_n= rd_win;
    assign wr_idxs_n= wr_win;
    assign free     = _DEPTH - used;
    assign used_scnt= `MIN(used, _RPORTS);
    assign free_scnt= `MIN(free, _WPORTS);

    // for (genvar i = 0; i < RPORTS; ++i)
    //     assign rd_nex[i] = incr(rd_win[RPORTS], `UCAST_FIT(i+1));
    // for (genvar i = 0; i < WPORTS; ++i)
    //     assign wr_nex[i] = incr(wr_win[WPORTS], `UCAST_FIT(i+1));
    for (genvar i = 0; i < RPORTS; ++i)
        assign rd_nex[i] = rd_win[RPORTS] + `UCAST_FIT(i+1);
    for (genvar i = 0; i < WPORTS; ++i)
        assign wr_nex[i] = wr_win[WPORTS] + `UCAST_FIT(i+1);

    DPTR [2*RPORTS:0]   rd_full;
    DPTR [2*WPORTS:0]   wr_full;
    assign rd_full = {rd_nex, rd_win};
    assign wr_full = {wr_nex, wr_win};

    typedef DPTR [RPORTS:0] RD_WIN_RESET;
    typedef DPTR [WPORTS:0] WR_WIN_RESET;
    function automatic RD_WIN_RESET gen_rd_win_res();
        RD_WIN_RESET rv;
        for (int unsigned i = 0; i < RPORTS+1; ++i) begin
            // int unsigned sum;
            // sum = RESET_STATE.head + i;
            // rv[i] = sum >= DEPTH ? 0 : sum;
            rv[i] = RESET_STATE.head + i;
        end
        return rv;
    endfunction
    function automatic WR_WIN_RESET gen_wr_win_res();
        WR_WIN_RESET rv;
        for (int unsigned i = 0; i < WPORTS+1; ++i) begin
            // int unsigned sum;
            // sum = RESET_STATE.tail + i;
            // rv[i] = sum >= DEPTH ? 0 : sum;
            rv[i] = RESET_STATE.tail + i;
        end
        return rv;
    endfunction
    localparam RD_WIN_RESET rd_win_res = gen_rd_win_res();
    localparam WR_WIN_RESET wr_win_res = gen_wr_win_res();


    localparam FLUSH_WIN_SZ = FLUSH_MODE == FIFO_FLUSH_SNAP_HEAD
        ? RPORTS
        : WPORTS;
    DPTR [FLUSH_WIN_SZ:0] flush_win;
    assign flush_win[0] = flush_snap;
    for (genvar i = 1; i <= FLUSH_WIN_SZ; ++i)
        assign flush_win[i] = flush_snap + `UCAST_FIT(i);

    always_ff @(posedge clock) begin
        if (flush) begin
            unique case (FLUSH_MODE)
            FIFO_FLUSH_SNAP_HEAD: begin
                // used <= used + distance(flush_snap, head) + wr_en_cnt;
                // used    <= used + `UCAST_LEN(distance(flush_snap, head) + wr_en_cnt, DEPTH); // or DEPTH+WPORTS?
                used    <= (tail - flush_snap) + wr_en_cnt;
                rd_win  <= flush_win;
                // wr_win <= wr_full[wr_en_cnt +: WPORTS+1];
                wr_win  <= wr_full >> shift_rom[wr_en_cnt];
            end

            FIFO_FLUSH_SNAP_TAIL: begin
                // used <= used - distance(flush_snap, tail) - rd_en_cnt;
                // used    <= used - `UCAST_LEN(distance(flush_snap, tail) + rd_en_cnt, DEPTH); // or DEPTH+RPORTS?
                used    <= (flush_snap - head) - rd_en_cnt;
                // rd_win <= rd_full[rd_en_cnt +: RPORTS+1];
                rd_win  <= rd_full >> shift_rom[rd_en_cnt];
                wr_win  <= flush_win;
            end

            default: begin
                used    <= RESET_STATE.used;
                rd_win  <= rd_win_res;
                wr_win  <= wr_win_res;
            end
            endcase

        end else begin
            // used <= used + wr_en_cnt - rd_en_cnt;
            used    <= `UCAST_LEN(used + wr_en_cnt, DEPTH+WPORTS) - rd_en_cnt;
                /* realistically the "WPORTS" safety margin is not necessary
                if we don't have internal forwarding */

            // rd_win <= rd_full[rd_en_cnt +: RPORTS+1];
            // wr_win <= wr_full[wr_en_cnt +: WPORTS+1];
            rd_win  <= rd_full >> shift_rom[rd_en_cnt];
            wr_win  <= wr_full >> shift_rom[wr_en_cnt];
        end

        if (reset) begin
            used    <= RESET_STATE.used;
            rd_win  <= rd_win_res;
            wr_win  <= wr_win_res;
        end

    end

endmodule


// old impl: head, tail pointers only
// module ring_ctr #(
//     parameter int DEPTH=2,
//     parameter int WIDTH=1,
//     parameter int RPORTS=1,
//     parameter int WPORTS=1,
//     parameter int FLUSH_MODE=FIFO_FLUSH_RESET,
//     type PTR = `IDX_TYPE(DEPTH),
//     type DPTR = `CNT_TYPE(DEPTH),
//     type RING_PTR_STATE = struct packed {
//         PTR head;
//         PTR tail;
//         DPTR used;
//     },
//     parameter int INSTANCE_ID=-1,
//     parameter RING_PTR_STATE RESET_STATE='{default:0}
// ) (
//     input   clock,
//     input   reset,
//     input   flush,
//     input   PTR     flush_snap,

//     input   `CNT_TYPE(RPORTS) rd_en_cnt,
//     input   `CNT_TYPE(WPORTS) wr_en_cnt,

//     output  PTR     head,
//     output  PTR     tail,
//     output  PTR     [RPORTS:0]          rd_idxs_n,
//     output  PTR     [WPORTS:0]          wr_idxs_n,

//     output  DPTR     used,
//     output  DPTR     free,
//     output  `CNT_TYPE(RPORTS) used_scnt,
//     output  `CNT_TYPE(WPORTS) free_scnt
// );
//     // casted constants
//     localparam `CNT_TYPE(DEPTH) _DEPTH  = DEPTH;
//     localparam `CNT_TYPE(RPORTS)_RPORTS = RPORTS;
//     localparam `CNT_TYPE(WPORTS)_WPORTS = WPORTS;

//     function automatic PTR incr(input PTR p, input int unsigned k);
//         logic [`CNT_SIZE(2*_DEPTH)-1:0] carry;
//         carry = p + k;
//         return (carry >= _DEPTH) ? carry - _DEPTH : carry;
//     endfunction
//     function automatic DPTR distance(input PTR x, input PTR y);
//         return (y >= x) ? (y - x) : (y + _DEPTH - x);
//     endfunction

//     assign free     = _DEPTH - used;
//     assign used_scnt= `MIN(used, _RPORTS);
//     assign free_scnt= `MIN(free, _WPORTS);

//     generate
//     assign rd_idxs_n[0] = head;
//     for (genvar i = 1; i < RPORTS+1; ++i) begin
//         assign rd_idxs_n[i] = incr(head, `UCAST_FIT(i));
//     end

//     assign wr_idxs_n[0] = tail;
//     for (genvar i = 1; i < WPORTS+1; ++i) begin
//         assign wr_idxs_n[i] = incr(tail, `UCAST_FIT(i));
//     end
//     endgenerate

//     always_ff @(posedge clock) begin
//         if (reset) begin
//             used <= RESET_STATE.used;
//             head <= RESET_STATE.head;
//             tail <= RESET_STATE.tail;

//         end else if (flush) begin
//             unique case (FLUSH_MODE)
//             FIFO_FLUSH_SNAP_HEAD: begin
//                 // used <= used + distance(flush_snap, head) + wr_en_cnt;
//                 used <= used + `UCAST_LEN(distance(flush_snap, head) + wr_en_cnt, DEPTH); // or DEPTH+WPORTS?
//                 head <= flush_snap;
//                 tail <= wr_idxs_n[wr_en_cnt];
//             end

//             FIFO_FLUSH_SNAP_TAIL: begin
//                 // used <= used - distance(flush_snap, tail) - rd_en_cnt;
//                 used <= used - `UCAST_LEN(distance(flush_snap, tail) + rd_en_cnt, DEPTH); // or DEPTH+RPORTS?
//                 head <= rd_idxs_n[rd_en_cnt];
//                 tail <= flush_snap;
//             end

//             default: begin
//                 used <= RESET_STATE.used;
//                 head <= RESET_STATE.head;
//                 tail <= RESET_STATE.tail;
//             end
//             endcase

//         end else begin
//             // used <= used + wr_en_cnt - rd_en_cnt;
//             used <= `UCAST_LEN(used + wr_en_cnt, DEPTH+WPORTS) - rd_en_cnt;
//                 /* realistically the "WPORTS" safety margin is not necessary
//                 if we don't have internal forwarding */

//             head <= rd_idxs_n[rd_en_cnt];
//             tail <= wr_idxs_n[wr_en_cnt];

//         end
//     end

// endmodule