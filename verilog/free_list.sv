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
    input rob2retire r_in,

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
   

    fifo #(
        .INSTANCE_ID(0),
        .DEPTH(DEPTH),
        .WIDTH(WIDTH),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .RESET_STATE(RESET_STATE)
    ) lst (
        .clock(clock),
        .reset(reset),

        .wr_en_cnt(r_in.r_en_cnt),
        .wr_data(r_in.t_old),

        .rd_en_cnt(d_in.free_d_en_cnt),
        .rd_data(d_out.d_ts),

        .free_scnt(d_out.free_rdy_scnt),
        .used_scnt() // do we need this? how would even retire return more pregs than in existence?
    );

endmodule