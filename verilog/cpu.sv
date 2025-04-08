/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  cpu.sv                                              //
//                                                                     //
//  Description :  Top-level module of the verisimple processor;       //
//                 This instantiates and connects the 5 stages of the  //
//                 Verisimple pipeline together.                       //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module cpu (
    input clock, // System clock
    input reset, // System reset

    input MEM_TAG   mem2proc_transaction_tag, // Memory tag for current transaction
    input MEM_BLOCK [1:0] mem2proc_data,            // Data coming back from memory
        /*
        Q: Why 2 mem blocks when each mem block supplies a double word
        i.e. 8 bytes i.e. 2 insns? Isn't this enough to support 2-size fetch?
        A (Justin): No, it is not; fetch at a double-word misaligned PC will
        straddle double word block boundaries.

        An address is "double word-aligned" iff its lowest 3 bits are 000.
        If PC_reg = 3'b100, the first instruction (PC) is in the *second half* of
        mem2proc_data[0], but the next instruction (PC + 4) is in the *first half*
        of mem2proc_data[1]. One memory block isn't enough to cover both.
        */
    //input MEM_TAG   mem2proc_data_tag,        // Tag for which transaction data is for

    //output MEM_COMMAND proc2mem_command, // Command sent to memory
    //output ADDR        proc2mem_addr,    // Address sent to memory
    //output MEM_BLOCK   proc2mem_data,    // Data sent to memory
    //output MEM_SIZE    proc2mem_size,    // Data size sent to memory

    // Note: these are assigned at the very bottom of the module
    output COMMIT_PACKET [`N-1:0] committed_insts,
    output ADDR [`N-1:0] PC_reg,

    // Debug outputs: these signals are solely used for debugging in testbenches
    // Do not change for project 3
    // You should definitely change these for project 4
    output rob2retire dbg_rob2retire,
    output btq2retire dbg_btq2retire,
    output retire2btq dbg_retire2btq,
    output sq2retire  dbg_sq2retire,
    output ADDR  if_NPC_dbg,
    output DATA  if_inst_dbg,
    output logic if_valid_dbg,
    output ADDR  if_id_NPC_dbg,
    output DATA  if_id_inst_dbg,
    output logic if_id_valid_dbg,
    output ADDR  id_ex_NPC_dbg,
    output DATA  id_ex_inst_dbg,
    output logic id_ex_valid_dbg,
    output ADDR  ex_mem_NPC_dbg,
    output DATA  ex_mem_inst_dbg,
    output logic ex_mem_valid_dbg,
    output ADDR  mem_wb_NPC_dbg,
    output DATA  mem_wb_inst_dbg,
    output logic mem_wb_valid_dbg
);
    /* Global controls*/
    logic flush;

    //////////////////////////////////////////////////
    //                                              //
    //                   Fetch                      //
    //                                              //
    //////////////////////////////////////////////////  

    fetch2decode f_2_decode;
    decode2fetch decode_2_f;
    retire2fetch retire_2_f;

    stage_if_p4 fetch_0(
        .clock(clock),          // system clock
        .reset(reset),          // system reset
        //input     [1:0] if_valid,       // only go to next PC when true
        .flush(flush),
        .d_in   (decode_2_f),
        .d_out  (f_2_decode),
        // .take_branch('0),    // taken-branch signal CHANGE!!!!!!
        // .branch_target('0),  // target pc: use if take_branch is TRUE CHANGE!!!!!!
        .r_in(retire_2_f),
        .Imem_data(mem2proc_data),      // data coming back from Instruction memory

        // tags from memory
        // input MEM_TAG  Imem2proc_transaction_tag, // Should be zero unless there is a response
        // input MEM_TAG  Imem2proc_data_tag,

        // output MEM_COMMAND  Imem_command, // Command sent to memory
        //output IF_ID_PACKET [1:0] if_packet,
        // output ADDR         Imem_addr, // address sent to Instruction memory
        .PC_reg(PC_reg)
    );



    //////////////////////////////////////////////////
    //                                              //
    //                   Decode                     //
    //                                              //
    //////////////////////////////////////////////////   
    decode2dispatch de_2_disp;
    dispatch2decode disp_2_de;

    stage_id_p4 decoder0 (
        // TODO: Sam's commit
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .f_in(f_2_decode),
        .f_out(decode_2_f),
        .d_in(disp_2_de),
        .d_out(de_2_disp)
    );

    //////////////////////////////////////////////////
    //                                              //
    //                   Dispatch                   //
    //                                              //
    //////////////////////////////////////////////////   

    rs2dispatch     rs_2_dispatch;
    dispatch2rs     dispatch_2_rs;
    rob2dispatch    rob_2_dispatch;
    dispatch2rob    dispatch_2_rob;
    dispatch2free_list dispatch_2_fl;
    free_list2dispatch fl_2_dispatch;
    dispatch2map_table dispatch_2_map;
    // map_table2rob rob_out;
    map_table2dispatch map_2_dispatch;
    dispatch2btq dispatch_2_btq;
    btq2dispatch btq_2_dispatch;
    execute2complete_tag ex_2_ctag;
    execute2complete_dat ex_2_cdat;
    dispatch2sq dispatch_2_sq;
    sq2dispatch sq_2_dispatch;

    dispatch dispatcher(
        .clock(clock),
        .reset(reset),
        .flush(flush),

        .decode_in(de_2_disp),
        .decode_out(disp_2_de),

        .rs_in(rs_2_dispatch),
        .rs_out(dispatch_2_rs),

        .rob_in(rob_2_dispatch),
        .rob_out(dispatch_2_rob),

        .ctag_in(ex_2_ctag),

        .free_in(fl_2_dispatch),
        .free_out(dispatch_2_fl),

        .sq_in(sq_2_dispatch),
        .sq_out(dispatch_2_sq),

        .btq_in(btq_2_dispatch),
        .btq_out(dispatch_2_btq),

        .map_in(map_2_dispatch),
        .map_out(dispatch_2_map)
    );

    //////////////////////////////////////////////////
    //                                              //
    //                  Retire                      //
    //                                              //
    //////////////////////////////////////////////////  
    rob2retire rob_2_retire;
    assign dbg_rob2retire = rob_2_retire;
    // TODO: collects from both rob2retire and btq2retire
    btq2retire btq_2_retire;
    assign dbg_btq2retire = btq_2_retire;
    retire2btq retire_2_btq;
    assign dbg_retire2btq = retire_2_btq;
    retire_final retire_exec;
    logic mispred;
    ADDR  mispred_target;
    sq2retire sq_2_retire;
    assign dbg_sq2retire = sq_2_retire;

    sq2retire HARDCODED_sq2retire;
    assign HARDCODED_sq2retire = '{
        ret_rdy : `N,
        sq_ret_complete : `TRUE
    };
    retire retire0 (
        .clock(clock),
        .reset(reset),
        .rob_in(rob_2_retire),
        .btq_in(btq_2_retire),
        .btq_out(retire_2_btq),

        /*
        FIXME: hardcoded sq_in
        If connected to true sq_2_retire, it stalls in `*.syn.out` (i.e.
        reaches max cycle limit), even if it doesn't stall in `*.out`.

        Actually I don't think this actually fixes the stalling problem.
        */
        .sq_in(HARDCODED_sq2retire),
        // .sq_out(),

        .mispred(mispred),
        .mispred_target(mispred_target),
        .retire_exec(retire_exec)
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            flush       <= '0;
            retire_2_f  <= '0;
        end else begin
/* ======================================== */
            flush       <= mispred;
            retire_2_f  <= '{corrected_PC : mispred_target};
/* ======================================== */
        end
    end


    //////////////////////////////////////////////////
    //                                              //
    //           Branch target queue (BTQ)          //
    //                                              //
    //////////////////////////////////////////////////  
    btq btq_0(
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .r_in (retire_2_btq),
        .r_out(btq_2_retire),
        .cdat_in(ex_2_cdat),
        .d_in(dispatch_2_btq),
        .d_out(btq_2_dispatch)
    );

    //////////////////////////////////////////////////
    //                                              //
    //              Reservation Station             //
    //                                              //
    //////////////////////////////////////////////////  
    execute2rs      ex_2_rs; 
    rs2execute      rs_2_ex;

    execute2prf     prf_out;
    prf2execute     prf_in;

    rs rs_0(
        .clock(clock),
        .reset(reset),
        .flush(flush),
 
        .d_out(rs_2_dispatch),
        .d_in(dispatch_2_rs),
 
        .ex_in(ex_2_rs),
        .ex_out(rs_2_ex),

        .ctag_in(ex_2_ctag)
    );
    
    //////////////////////////////////////////////////
    //                                              //
    //                Re-Order Buffer               //
    //                                              //
    //////////////////////////////////////////////////  

    rob2sq rob_2_sq;

    rob #(
        .ROB_SZ(`ROB_SZ),
        .N(`N)
    ) rob_0 (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .r_out      (rob_2_retire),
        .r_in       (retire_exec),
        .cdat_in    (ex_2_cdat),
        .d_out      (rob_2_dispatch),
        .d_in       (dispatch_2_rob),
        .sq_in      (sq_2_retire),
        .sq_out     (rob_2_sq)
    );

    //////////////////////////////////////////////////
    //                                              //
    //                      SQ                      //
    //                                              //
    ////////////////////////////////////////////////// 

    execute2sq exec_2_sq;
    // MEM_TAG mem2proc_transaction_tag;
    MEM_TAG temp_tag;

    sq2execute sq_2_exec;
    stRET2mem ret_2_mem;
    assign temp_tag = (ret_2_mem.Dmem_command == MEM_STORE) ? 1 : 0;

    sq #(
        .N(`N),
        .LSQ_SZ(`LSQ_SZ),
        .LSQ_SZ_DBL(`LSQ_SZ_DBL),
        .NUM_FU_STORE(`NUM_FU_STORE),
        .NUM_FU_LOAD(`NUM_FU_LOAD)
    ) sq_0 (
        .clock(clock),
        .reset(reset),
        .flush(flush),

        .dis_2_sq(dispatch_2_sq),
        .exec_2_sq(exec_2_sq),
        .rob_2_sq(rob_2_sq), //using the rob_2_sq packet here seems to be causing false retirements from the SQ. Will investigate Sunday 4/6. 
        //As is, can still see packets entering the SQ, and should be able to retire the top 2 entries "properly", they just won't actually write to memory.
        //But this will still work if you just want to make sure that you can actually make it through a program to the wfi
        .mem2proc_transaction_tag(temp_tag),

        .sq_2_dis(sq_2_dispatch),
        .sq_2_exec(sq_2_exec),
        .sq_2_retire(sq_2_retire),
        .ret_2_mem(ret_2_mem)
);


    //////////////////////////////////////////////////
    //                                              //
    //                  Execute                     //
    //                                              //
    ////////////////////////////////////////////////// 

    
    execute2lq ex_2_lq;
    stage_ex_p4 ex_0 (
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .rs_in(rs_2_ex),
        .rs_out(ex_2_rs),

        .sq_in(sq_2_exec),
        .sq_out(exec_2_sq), // TODO: hook up to sq
        .lq_out(ex_2_lq), // TODO: hook up to lq

        .ctag_out(ex_2_ctag),
        .cdat_out(ex_2_cdat),
        .prf_out(prf_out),
        .prf_in(prf_in)
    );



    //////////////////////////////////////////////////
    //                                              //
    //                  Map Table                   //
    //                                              //
    //////////////////////////////////////////////////  

    arch_map2map_table am_2_mt;
    map_table #(
        .N(`N)
    ) map_table_0 (
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .am_in(am_2_mt),
        .d_in(dispatch_2_map),
        .d_out(map_2_dispatch)
    );

    //////////////////////////////////////////////////
    //                                              //
    //           Architectural Map Table            //
    //                                              //
    //////////////////////////////////////////////////  

    arch_map #(
        .N(`N)
    ) arch_map_0 (
        .clock(clock),
        .reset(reset),
        .mt_out(am_2_mt),
        .r_in(retire_exec)
    );

    //////////////////////////////////////////////////
    //                                              //
    //                  Free List                   //
    //                                              //
    //////////////////////////////////////////////////  

    free_list #(
        .N(`N)
    ) free_list_0 (
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .r_in(retire_exec),
        .d_in(dispatch_2_fl),
        .d_out(fl_2_dispatch)
    );

    //////////////////////////////////////////////////
    //                                              //
    //            Physical Register File            //
    //                                              //
    //////////////////////////////////////////////////  

    prf #(
        .WIDTH(32),
        .DEPTH(`PHYS_REG_SZ_R10K),
        .N(`N),
        .BYPASS_EN(1)
    ) prf_0 (
        .clock(clock),
        //.reset(reset),
        //.flush(),
        .c_en   (ex_2_cdat.en),
        .c_is_brch (ex_2_cdat.is_brch),
        .c_ts   (ex_2_cdat.ts),
        .c_vs   (ex_2_cdat.data),

        // NOTE: Here each X_BY_FU type is coerced into a flat X array type
        .s_en1s (prf_out.s_en1s),
        .s_en2s (prf_out.s_en2s),
        .s_t1s  (prf_out.s_t1s),
        .s_t2s  (prf_out.s_t2s),
        .s_v1s  (prf_in.s_v1s),
        .s_v2s  (prf_in.s_v2s)
    );


    // //////////////////////////////////////////////////
    // //                                              //
    // //               Pipeline Outputs               //
    // //                                              //
    // //////////////////////////////////////////////////

    // // Output the committed instruction to the testbench for counting
    always_comb begin
        committed_insts = '0;
        foreach(committed_insts[i]) begin
            if (flush) // system is flushing; CANNOT COMMIT!
                break;
            if (i >= retire_exec.r_en_cnt)
                continue;
            committed_insts[i].valid      = 1;
            committed_insts[i].halt       = retire_exec.halt[i];
            committed_insts[i].illegal    = retire_exec.illegal[i];
        end
    end


endmodule // pipeline
