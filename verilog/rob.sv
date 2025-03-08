// Simple FIFO with parametrizable depth and width
/*
min: clock period:
make -B syn CLOCK_PERIOD=1.9
*/

`include "sys_defs.svh"


module rob #(
    parameter DEPTH = `ROB_SZ,  // num elements
    parameter WIDTH = $bits(ROB_ENTRY),  // num bits per element 
                           //(32 bits per insn + log2(64) = 6 bits each for T & Told)
    parameter N=`N,
    localparam CNT_BITS = $clog2(DEPTH)
) (
    input                       clock, reset,

    // retire (read)
    output struct packed {
        logic [N-1:0]           r_en;

        PHYS_REG_IDX [N-1:0]    tag;
        PHYS_REG_IDX [N-1:0]    t_old;
    } r_out,

    // complete (write)
    input struct packed {
        logic [N-1:0]           c_en;
            // - From: EX
        PHYS_REG_IDX [N-1:0]    c_ts;
            // - From: EX
        ROB_IDX [N-1:0]         c_rob_idxs;
            // - From: EX
            // - It's either this OR c_ts. If we have c_ts, then we CAM in ROB. If
            // we have c_rob_idxs, we index into ROB.
    } c_in,

    // dispatch (write)
    output struct packed {
        logic [$clog2(N):0]     rob_rdy_scnt;
            // To: dispatch
            // saturating counter for number of free rob entries
    } d_out,
    input struct packed {
        logic [$clog2(N):0]     d_en_cnt;
            // From: dispatch
            // - Number of enabled dispatch lines?
        ROB_ENTRY   [N-1:0]     d_dat;
            // From: dispatch
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } d_in
);

  

//   FIFO myfifo (
//       .clock(clock),
//       .reset(reset),
//       .wr_en(dispatch_en),
//       .rd_en(retire_en),
//       .err(err),
//       .wr_data(next_insn),
//       .wr_valid(wr_valid),
//       .rd_valid(rd_valid),
//       .rd_data(completed_insn),
//       .spots(free_spots),
//       .full(full)
//   );
endmodule
