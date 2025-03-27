`include "sys_defs.svh"

/* 
================================================
Free List
================================================
*/
module free_list #(parameter 
    N=`N
) (
    input clock, reset, flush,
    // retire
    input retire_final r_in,

    // complete ?? 
    // issue ??

    // dispatch
    input dispatch2free_list d_in,
    
    output free_list2dispatch d_out
);
    localparam DEPTH = `ROB_SZ;
    localparam WIDTH = $bits(PHYS_REG_IDX);
    typedef struct packed {
        logic [$clog2(DEPTH)-1:0]       head;
        logic [$clog2(DEPTH)-1:0]       tail;
        logic [DEPTH-1:0][WIDTH-1:0]    state;
        logic [$clog2(DEPTH):0]         used;
    } FIFO_STATE;

    function automatic FIFO_STATE gen_reset_state();
        logic [DEPTH-1:0][WIDTH-1:0] state;
        logic [WIDTH-1:0] start = 32;
        for (int unsigned i = 0; i < $unsigned(DEPTH); ++i) begin
            state[i] = start + i;
        end
        return '{
            head:0,
            tail:0,
            state:state,
            used:DEPTH
        };
    endfunction
    localparam FIFO_STATE RESET_STATE = gen_reset_state();
   

    /*
    TODO [RESOLVED]: *IMPORTANT* retire zero_reg edge case!
    If the retiring insn has no real output register (e.g. hlt, store), then
    its destination will be the zero preg. You MUST NOT allow a zero preg
    to be added to the free list (this is causing the free_list FIFO
    overflow in the commit in which this comment was added.
    SHA: f24016e5a7d6a931ac32b72020fd154b3cfcc57c). 
    
    This presents a problem: our fifo.sv impl operates on counts, and assumes
    wr_data is contiguously filled from lowest indices. However, not all
    retiring insns with valid output pregs will be at the lowest indices
    (e.g. vld_preg_out? : [0, 1]). Two solutions for this:
    1. Form another intermediate N-wide array that compresses all retiring
    insns with valid output registers to the lowest indices, before sending
    it to free_list (a "packing loop" logic).

    e.g., In a 3-wide processor. retire stage sees:
        [0] -> valid, dst = 5
        [1] -> valid, dst = 0 (zero_reg - must skip!)
        [2] -> valid, dst = 6
    Must compress to [5, 6] before sending to free_list.

    2. Rewrite FIFO to accept valid buses instead of counts (however I believe
    lowest-index contiguity via counts offers performance advantages which
    other FIFOs like the decode or fetch FIFOs can, and *should*, exploit.)

    In addition, it seems 2 is only shifting the work of the "packing loop" into
    the FIFO (you still have to do it *somewhere*).
    */
    logic [$clog2(`N):0] free_cnt;
    PHYS_REG_IDX [`N-1:0] told_packed;
    always_comb begin
        free_cnt    = 0;
        told_packed = '0;

        // pack all returning pregs to lowest indices
        for (int unsigned i = 0; i < r_in.r_en_cnt; ++i) begin
            if (r_in.t_old[i] != `ZERO_REG)
                told_packed[free_cnt++] = r_in.t_old[i]; // postfix ++ (important!)
        end
    end
   

    fifo #(
        .INSTANCE_ID(0),
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_FREE_LIST_MODE(`TRUE),
        .ENABLE_INTR_FWD(`FALSE),
        .RESET_STATE(RESET_STATE)
    ) lst (
        .clock(clock),
        .reset(reset),
        .flush(flush),

        .wr_en_cnt(free_cnt),
        .wr_data(told_packed),

        .rd_en_cnt(d_in.free_d_en_cnt),
        .rd_data(d_out.d_ts),

        .free_scnt(), // do we need this? how would even retire return more pregs than in existence?
        .used_scnt(d_out.free_rdy_scnt)
    );

    // debugging
    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("  %3d | >> Free list", $time);
    //         $display("rob2retire: {r_en_cnt: %d, [(t: %0d, told: %0d, dst: %0d), (t: %0d, told: %0d, dst: %0d)]}",
    //             r_in.r_en_cnt,
    //             r_in.tag[0],
    //             r_in.t_old[0],
    //             r_in.dst[0],
    //             r_in.tag[1],
    //             r_in.t_old[1],
    //             r_in.dst[1]
    //         );
    //         $display("d_in:  {d_en_cnt: %d}",
    //             d_in.free_d_en_cnt
    //         );
    //         $display("d_out: {free_rdy_scnt: %d, [%0d, %0d]}",
    //             d_out.free_rdy_scnt,
    //             d_out.d_ts[0],
    //             d_out.d_ts[1]
    //         );
    //         $display("  %3d | << Free list", $time);
    //     end
    // end

endmodule