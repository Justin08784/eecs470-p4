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
    input   BMASK clmsk,
    input   WADDR flush_PC,

    input   decode2fetch d_in,
    output  fetch2decode d_out,

    input   btq2fetch   btq_in,
    output  fetch2btq   btq_out,

    // execute
    input   execute2complete_bru cbru_in,

    input   rename2snap_bus snap_in,

    output  fetch2mem   mem_out,
    input   mem2fetch   mem_in
);
    WADDR PC_reg;       // base PC for this cycle
    WADDR [`N:0] PC_n;  // PC_n[m] := next PC if we fetch "m" this cycle (inaccurate past the 1st branch)

    logic [$clog2(`N):0]    free_scnt, used_scnt, f_cnt;
    logic [`N-1:0] f_en;
    IF_ID_PACKET [`N-1:0]   f_dat;

    always_comb begin
        DWADDR PC_dw;
        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);

        PC_n[0] = PC_reg;
        for (int i = 0; i < `N; ++i)
            PC_n[i+1] = PC_reg + (i+1);

        PC_dw = PC_reg[13:1]; // w -> dw
        for (int i = 0; i < `N; ++i)
            mem_out.PCdws[i] = PC_dw + i;
    end


    // Align
    BRANCH_MD [2*`N-1:0] md_raw;
    INST      [2*`N-1:0] inst_raw;
    BRANCH_MD [`N-1:0] md;
    INST      [`N-1:0] inst;
    generate
    for (genvar i = 0; i < `N; ++i) begin
        for (genvar woff = 0; woff < 2; ++woff) begin
            assign md_raw   [2*i + woff] = mem_in.insn_md[i][woff];
            assign inst_raw [2*i + woff] = mem_in.data[i].word_level[woff];
        end
    end

    logic base_woff;
    assign base_woff = PC_reg[0];
    for (genvar i = 0; i < `N; ++i) begin
        assign md[i]    = base_woff ? md_raw    [i+1] : md_raw  [i];
        assign inst[i]  = base_woff ? inst_raw  [i+1] : inst_raw[i];
    end
    endgenerate

    logic [`N-1:0] brch, cond, call, ret;
    generate
    for (genvar i = 0; i < `N; ++i) begin
        assign brch[i] = md[i].branch;
        assign cond[i] = md[i].cond;
        assign call[i] = md[i].call;
        assign ret[i]  = md[i].ret;
    end
    endgenerate

    // always_ff @(posedge clock) begin
    //     if (!reset) begin
    //         $display("PC_dws: [%x, %x]", mem_out.PCdws[0], mem_out.PCdws[1]);
    //         $display("mem_in: [%x, %x, %x, %x]",
    //         mem_in.data[0].word_level[0],
    //         mem_in.data[0].word_level[1],
    //         mem_in.data[1].word_level[0],
    //         mem_in.data[1].word_level[1]
    //         );
    //         $display("base_woff: %b", base_woff);

    //         $display("md_raw: %x, %x, %x, %x", md_raw[0], md_raw[1], md_raw[2], md_raw[3]);
    //         $display("inst_raw: %x, %x, %x, %x", inst_raw[0], inst_raw[1], inst_raw[2], inst_raw[3]);

    //         $display("md: %x, %x", md[0], md[1]);
    //         $display("inst: %x, %x", inst[0], inst[1]);
    //     end
    // end

    fetch2bp bp_qry;
    assign bp_qry = '{
        brch    : brch,
        cond    : cond,
        call    : call,
        ret     : ret,

        PC_n    : PC_n,
        f_en    : f_en
    };

    bp2fetch bp_res;
    logic [`N-1:0] pred;
    WADDR [`N-1:0] pred_tgt;
    assign pred     = bp_res.take;
    assign pred_tgt = bp_res.tgt;
    bp bp0 (
        .clock,
        .reset,
        .flush,
        .clmsk,
        .snap_in,

        .f_in       (bp_qry),
        .f_out      (bp_res),

        .cbru_in,

        .i_upd      (btq_in.bp_upd)
    );


    logic [`N:0][$clog2(`N):0] btq_prefix_cnt;
    logic [$clog2(`N):0] btq_lim_cnt;
    compactor #(
        .REQW(`N),
        .GNTW(`N)
    ) comp_btq (
        .req        (brch),
        .lim_cnt    (btq_in.btq_rdy_scnt),
        .prefix_cnt (btq_prefix_cnt),
        .gnt_cnt    (btq_lim_cnt)
    );

    always_comb begin
        for (int unsigned i = 0; i < `N; ++i) begin
            f_dat[i] = '{
                inst    : inst[i],
                PC      : PC_n[i],
                ras_snap: bp_res.ras_snap[i],
                btq_idx : '0 // filled below
            };
        end

        // handle btq output
        btq_out = '0;
        f_cnt = `MIN(btq_lim_cnt, free_scnt);
        for (int i = 0; i < `N; ++i)
            f_en[i] = i < f_cnt;
            /* ^ want this f_en to be "pre BP f_en". bp_lim_cnt is redundant to BP
            since BP derives it in the first place */
        f_cnt = `MIN(bp_res.lim_cnt, f_cnt);

        btq_out.en_cnt = btq_prefix_cnt[f_cnt];
        for (int i = 0; i < `N; ++i) begin
            f_dat[i].btq_idx = btq_in.btq_idxs_n[btq_prefix_cnt[i]];

            btq_out.PC      [btq_prefix_cnt[i]] = PC_n[i];
            btq_out.pred    [btq_prefix_cnt[i]] = pred[i];
            btq_out.pred_tgt[btq_prefix_cnt[i]] = pred_tgt[i];
            btq_out.ret     [btq_prefix_cnt[i]] = ret[i];
        end

    end

    // always_ff @(posedge clock) begin
    //     $display("reset: %b, btq_out.en_cnt: %d, f_cnt: %d", reset, btq_out.en_cnt, f_cnt);
    //     $display("fluck: %b", fluck);
    //     for (int i = 0; i < `N+1; ++i)
    //         $display("> btq_prefix_cnt[%1d]: %1d", i, btq_prefix_cnt[i]);
    // end


    fifo #(
        .DEPTH(2*`N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .FLUSH_MODE(FIFO_FLUSH_RESET),
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
        logic [2*`N-1:0] insn_buf_vld;

        $display(">> Fetch >>");
        // insn_buf_vld = '0;
        // for (int cnt = 0; cnt < insn_buf.used; ++cnt)
        //     insn_buf_vld[(insn_buf.head + cnt) % (2*`N)] = 1;
        // $display("insn_buf_vld: %b", insn_buf_vld);
        // for (int i = 0; i < `N; ++i)
        //     $display("[%1d]: %1d", i, btq_prefix_cnt[i]);
        $display("flush: %b, flush_PC: 0x%x", flush, flush_PC);
        $display("d_out: {f_en_cnt: %b, dat: [%x, %x]}", d_out.f_en_cnt, d_out.f_dat[0], d_out.f_dat[1]);
        $display("<< Fetch <<");
    endtask
`endif

endmodule // stage_if
