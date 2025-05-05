/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_if.sv                                         //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module stage_if_p4 (
`ifdef DEBUG
    output  DBG_fetch dbg,
`endif

    input   clock,
    input   reset,
    input   flush,
    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   retire2fetch r_in,

    output  ADDR        [`N-1:0] mem_out_PCs,
    input   MEM_BLOCK   [`N-1:0] mem_in_data
);
    ADDR PC_reg;        // base PC for this cycle
    ADDR [`N:0] PC_n;   // PC_n[m] := next PC if we fetch "m" this cycle (inaccurate past the 1st branch)

    logic [$clog2(`N):0]    free_scnt, used_scnt, f_cnt;
    IF_ID_PACKET [`N-1:0]   f_dat;

    always_comb begin
        logic woff;

        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);
        f_cnt = free_scnt < `N ? 0 : `N; // no partial fetches (for simplicity)! 

        PC_n[0] = PC_reg;
        for (int i = 0; i < `N; ++i) begin
            PC_n[i + 1] = PC_reg + 4*(i + 1);
            mem_out_PCs[i] = PC_n[i];
        end

        for (int unsigned i = 0; i < `N; ++i) begin
            woff = mem_out_PCs[i][2];

            f_dat[i] = '{
                inst    : mem_in_data[i].word_level[woff],
                PC      : PC_n[i],
                NPC     : PC_n[i] + 4,
                pred    : 1'b0,
                pred_tgt: '0
            };
        end
    end

    fifo #(
        .DEPTH(2*`N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) dut (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .wr_en_cnt  (f_cnt),
        .wr_data    (f_dat),
        .rd_en_cnt  (d_out.f_en_cnt),
        .rd_data    (d_out.f_dat),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            PC_reg <= 0;                    // initial PC value is 0 (the memory address where our program starts)
        end else if (flush) begin
            PC_reg <= r_in.corrected_PC;    // update to a taken branch (does not depend on valid bit)...
        end else begin
            PC_reg <= PC_n[f_cnt];          // ...or transition to next PC if valid
        end
    end

`ifdef DEBUG
    assign dbg = '{
        flush : flush,
        d_in  : d_in,
        d_out : d_out,
        r_in  : r_in,
        mem_out_PCs : mem_out_PCs, 
        mem_in_data : mem_in_data
    };
`endif

endmodule // stage_if