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
    input   clock,
    input   reset,
    input   flush,
    input   WADDR flush_PC,

    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   btq2fetch   btq_in,
    output  fetch2btq   btq_out,

    output  fetch2mem   mem_out,
    input   mem2fetch   mem_in
);
    WADDR PC_reg;       // base PC for this cycle
    WADDR [`N:0] PC_n;  // PC_n[m] := next PC if we fetch "m" this cycle (inaccurate past the 1st branch)

    logic [$clog2(`N):0]    free_scnt, used_scnt, f_cnt;
    IF_ID_PACKET [`N-1:0]   f_dat;

    always_comb begin
        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);

        PC_n[0] = PC_reg;
        for (int i = 0; i < `N; ++i) begin
            PC_n[i + 1] = PC_reg + i + 1;
            mem_out.PCs[i] = w2addr(PC_n[i]);
        end
    end

    fetch2btb f2btb;
    btb2fetch btb2f;
    logic [`N-1:0] is_brch;
    logic [`N-1:0] pred;
    WADDR [`N-1:0] pred_tgt;
    always_comb begin
        logic woff;
        foreach (is_brch[i]) begin
            woff = PC_n[i][0];
            is_brch[i] = (mem_in.insn_md[i][woff].cond_branch
                       || mem_in.insn_md[i][woff].uncond_branch);

            f2btb.pc[i] = PC_n[i];

            pred[i]     = is_brch[i] && btb2f.vld[i];
            pred_tgt[i] = btb2f.tgt[i];
        end
    end

    puq2btb puq_2_btb;
    assign puq_2_btb = '{
        en  : btq_in.puq_en,
        pc  : btq_in.puq_dat.pc,
        tgt : btq_in.puq_dat.tgt
    };
    btb btb0 (
        .clock,
        .reset,

        .f_in (f2btb),
        .f_out(btb2f),

        .puq_in(puq_2_btb)
    );

    logic [`N:0][$clog2(`N):0] btq_prefix_cnt;
    logic [$clog2(`N):0] btq_lim_cnt;
    compactor #(
        .WIDTH(`N)
    ) comp_btq (
        .req        (is_brch),
        .rdy        (btq_in.btq_rdy_scnt),
        .gnt_cnt    (btq_lim_cnt),
        .prefix_cnt (btq_prefix_cnt)
    );

    always_comb begin
        // stop fetching beyond the first predicted taken branch
        f_cnt = 0;
        for (int i = 0; i < `N; ++i) begin
            if (i >= free_scnt)
                break;
            f_cnt = i + 1;
            if (pred[i]) begin
                break;
            end
        end


        for (int unsigned i = 0; i < `N; ++i) begin
            logic woff;
            woff = PC_n[i][0];

            f_dat[i] = '{
                inst    : mem_in.data[i].word_level[woff],
                PC      : PC_n[i],
                btq_idx : '0 // filled below
            };
        end

        // handle btq output
        btq_out = '0;
        f_cnt = `MIN(btq_lim_cnt, f_cnt);
        btq_out.en_cnt = btq_prefix_cnt[f_cnt];
        for (int i = 0; i < `N; ++i) begin
            f_dat[i].btq_idx = btq_in.btq_idxs[btq_prefix_cnt[i]];

            btq_out.PC      [btq_prefix_cnt[i]] = PC_n[i];
            btq_out.pred    [btq_prefix_cnt[i]] = pred[i];
            btq_out.pred_tgt[btq_prefix_cnt[i]] = pred_tgt[i];
        end


    end

    fifo #(
        .DEPTH(2*`N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) insn_buf (
        .clock,
        .reset,
        .flush,
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
            PC_reg <= flush_PC;    // update to a taken branch (does not depend on valid bit)...
        end else begin                      // ...or transition to next PC if valid
            PC_reg <= 
                f_cnt == 0    ? PC_reg :
                pred[f_cnt-1] ? pred_tgt[f_cnt-1] : PC_n[f_cnt];
        end
    end

`ifdef DEBUG
    task print_fetch;
        $display(">> Fetch >>");
        $display("flush: %b, flush_PC: 0x%x", flush, flush_PC);
        $display("d_out: {f_en_cnt: %b, dat: [%x, %x]}", d_out.f_en_cnt, d_out.f_dat[0], d_out.f_dat[1]);
        $display("<< Fetch <<");
    endtask
`endif

endmodule // stage_if
