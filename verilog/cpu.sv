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

    //input MEM_TAG   mem2proc_transaction_tag, // Memory tag for current transaction
    input MEM_BLOCK mem2proc_data,            // Data coming back from memory
    //input MEM_TAG   mem2proc_data_tag,        // Tag for which transaction data is for

    //output MEM_COMMAND proc2mem_command, // Command sent to memory
    //output ADDR        proc2mem_addr,    // Address sent to memory
    //output MEM_BLOCK   proc2mem_data,    // Data sent to memory
    //output MEM_SIZE    proc2mem_size,    // Data size sent to memory

    // Note: these are assigned at the very bottom of the module
    output COMMIT_PACKET [`N-1:0] committed_insts,
    output ADDR PC_reg,

    // Debug outputs: these signals are solely used for debugging in testbenches
    // Do not change for project 3
    // You should definitely change these for project 4
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

    //////////////////////////////////////////////////
    //                                              //
    //                Pipeline Wires                //
    //                                              //
    //////////////////////////////////////////////////

    // // Pipeline register enables
    // logic if_id_enable, id_ex_enable, ex_mem_enable, mem_wb_enable;

    // // From IF stage to memory
    // MEM_COMMAND Imem_command; // Command sent to memory

    // // Outputs from IF-Stage and IF/ID Pipeline Register
    // ADDR Imem_addr;
    // IF_ID_PACKET if_packet, if_id_reg;

    // // Outputs from ID stage and ID/EX Pipeline Register
    // ID_EX_PACKET id_packet, id_ex_reg;

    // // Outputs from EX-Stage and EX/MEM Pipeline Register
    // EX_MEM_PACKET ex_packet, ex_mem_reg;

    // // Outputs from MEM-Stage and MEM/WB Pipeline Register
    // MEM_WB_PACKET mem_packet, mem_wb_reg;

    // // Outputs from MEM-Stage to memory
    // ADDR        Dmem_addr;
    // MEM_BLOCK   Dmem_store_data;
    // MEM_COMMAND Dmem_command;
    // MEM_SIZE    Dmem_size;

    // // Outputs from WB-Stage (These loop back to the register file in ID)
    // COMMIT_PACKET wb_packet;

    // // Logic for stalling memory stage
    // logic       load_stall;
    // logic       new_load;
    // logic       mem_tag_match;
    // logic       rd_mem_q;       // previous load
    // MEM_TAG     outstanding_mem_tag;    // tag load is waiting in
    // MEM_COMMAND Dmem_command_filtered;  // removes redundant loads

    // //////////////////////////////////////////////////
    // //                                              //
    // //                Memory Outputs                //
    // //                                              //
    // //////////////////////////////////////////////////

    // // these signals go to and from the processor and memory
    // // we give precedence to the mem stage over instruction fetch
    // // note that there is no latency in project 3
    // // but there will be a 100ns latency in project 4

    // always_comb begin
    //     if (Dmem_command != MEM_NONE) begin  // read or write DATA from memory
    //         proc2mem_command = Dmem_command_filtered;
    //         proc2mem_size    = Dmem_size;
    //         proc2mem_addr    = Dmem_addr;
    //     end else begin                      // read an INSTRUCTION from memory
    //         proc2mem_command = Imem_command;
    //         proc2mem_addr    = Imem_addr;
    //         proc2mem_size    = DOUBLE;      // instructions load a full memory line (64 bits)
    //     end
    //     proc2mem_data = Dmem_store_data;
    // end

    // //////////////////////////////////////////////////
    // //                                              //
    // //                  Valid Bit                   //
    // //                                              //
    // //////////////////////////////////////////////////

    // // This state controls the stall signal that artificially forces IF
    // // to stall until the previous instruction has completed.
    // // For project 3, start by assigning if_valid to always be 1

    // logic if_valid, start_valid_on_reset, wb_valid;


    // always_ff @(posedge clock) begin
    //     // Start valid on reset. Other stages (ID,EX,MEM,WB) start as invalid
    //     // Using a separate always_ff is necessary since if_valid is combinational
    //     // Assigning if_valid = reset doesn't work as you'd hope :/
    //     start_valid_on_reset <= reset;
    // end

    // // valid bit will cycle through the pipeline and come back from the wb stage
    // assign if_valid = start_valid_on_reset || wb_valid;

    // //////////////////////////////////////////////////
    // //                                              //
    // //                  IF-Stage                    //
    // //                                              //
    // //////////////////////////////////////////////////

    // stage_if stage_if_0 (
    //     // Inputs
    //     .clock (clock),
    //     .reset (reset),
    //     .if_valid      (if_valid),
    //     .take_branch   (ex_mem_reg.take_branch),
    //     .branch_target (ex_mem_reg.alu_result),
    //     .Imem_data     (mem2proc_data),
        
    //     //.Imem2proc_transaction_tag(mem2proc_transaction_tag),
    //     //.Imem2proc_data_tag       (mem2proc_data_tag),

    //     // Outputs
    //     //.Imem_command  (Imem_command),
    //     .if_packet     (if_packet),
    //     //.Imem_addr     (Imem_addr)
    //     .PC_reg        (PC_reg),
    //     .PC_reg4       (PC_reg4)
    // );

    // // debug outputs
    // assign if_NPC_dbg   = if_packet.NPC;
    // assign if_inst_dbg  = if_packet.inst;
    // assign if_valid_dbg = if_packet.valid;

    // //////////////////////////////////////////////////
    // //                                              //
    // //            IF/ID Pipeline Register           //
    // //                                              //
    // //////////////////////////////////////////////////

    // assign if_id_enable = !load_stall;

    // always_ff @(posedge clock) begin
    //     if (reset) begin
    //         if_id_reg.inst  <= `NOP;
    //         if_id_reg.valid <= `FALSE;
    //         if_id_reg.NPC   <= 0;
    //         if_id_reg.PC    <= 0;
    //     end else if (if_id_enable) begin
    //         if_id_reg <= if_packet;
    //     end
    // end

    // // debug outputs
    // assign if_id_NPC_dbg   = if_id_reg.NPC;
    // assign if_id_inst_dbg  = if_id_reg.inst;
    // assign if_id_valid_dbg = if_id_reg.valid;

    // //////////////////////////////////////////////////
    // //                                              //
    // //                  ID-Stage                    //
    // //                                              //
    // //////////////////////////////////////////////////

    // stage_id stage_id_0 (
    //     // Inputs
    //     .clock (clock),
    //     .reset (reset),
    //     .if_id_reg       (if_id_reg),
    //     .wb_regfile_en   (wb_packet.valid),
    //     .wb_regfile_idx  (wb_packet.reg_idx),
    //     .wb_regfile_data (wb_packet.data),

    //     // Output
    //     .id_packet (id_packet)
    // );

    // //////////////////////////////////////////////////
    // //                                              //
    // //            ID/EX Pipeline Register           //
    // //                                              //
    // //////////////////////////////////////////////////

    // assign id_ex_enable = !load_stall;

    // always_ff @(posedge clock) begin
    //     if (reset) begin
    //         id_ex_reg <= '{
    //             `NOP, // we can't simply assign 0 because NOP is non-zero
    //             32'b0, // PC
    //             32'b0, // NPC
    //             32'b0, // rs1 select
    //             32'b0, // rs2 select
    //             OPA_IS_RS1,
    //             OPB_IS_RS2,
    //             `ZERO_REG,
    //             ALU_ADD,
    //             1'b0, // mult
    //             1'b0, // rd_mem
    //             1'b0, // wr_mem
    //             1'b0, // cond
    //             1'b0, // uncond
    //             1'b0, // halt
    //             1'b0, // illegal
    //             1'b0, // csr_op
    //             1'b0  // valid
    //         };
    //     end else if (id_ex_enable) begin
    //         id_ex_reg <= id_packet;
    //     end
    // end

    // // debug outputs
    // assign id_ex_NPC_dbg   = id_ex_reg.NPC;
    // assign id_ex_inst_dbg  = id_ex_reg.inst;
    // assign id_ex_valid_dbg = id_ex_reg.valid;

    // //////////////////////////////////////////////////
    // //                                              //
    // //                  EX-Stage                    //
    // //                                              //
    // //////////////////////////////////////////////////

    // // stage_ex stage_ex_0 (
    // //     // Input
    // //     .id_ex_reg (id_ex_reg),

    // //     // Output
    // //     .ex_packet (ex_packet)
    // // );

    // //////////////////////////////////////////////////
    // //                                              //
    // //           EX/MEM Pipeline Register           //
    // //                                              //
    // //////////////////////////////////////////////////

    // assign ex_mem_enable = !load_stall;

    // always_ff @(posedge clock) begin
    //     if (reset) begin
    //         ex_mem_inst_dbg <= `NOP; // debug output
    //         ex_mem_reg      <= 0;    // the defaults can all be zero!
    //     end else if (ex_mem_enable) begin
    //         ex_mem_inst_dbg <= id_ex_inst_dbg; // debug output, just forwarded from ID
    //         ex_mem_reg      <= ex_packet;
    //     end
    // end

    // // debug outputs
    // assign ex_mem_NPC_dbg   = ex_mem_reg.NPC;
    // assign ex_mem_valid_dbg = ex_mem_reg.valid;

    // //////////////////////////////////////////////////
    // //                                              //
    // //                 MEM-Stage                    //
    // //                                              //
    // //////////////////////////////////////////////////

    // // New address if:
    // // 1) Previous instruction wasn't a load
    // // 2) Load address changed
    // logic valid_load;
    // assign valid_load = ex_mem_reg.valid && ex_mem_reg.rd_mem; 
    // assign new_load = valid_load && !rd_mem_q;

    // assign mem_tag_match = outstanding_mem_tag == mem2proc_data_tag;
    // assign load_stall    = new_load || (valid_load && !mem_tag_match);

    // assign Dmem_command_filtered = new_load || ex_mem_reg.wr_mem ? Dmem_command : MEM_NONE;

    // always_ff @(posedge clock) begin
    //     if (reset) begin
    //         rd_mem_q            <= 1'b0;
    //         outstanding_mem_tag <= '0;
    //     end else begin
    //         rd_mem_q            <= valid_load;
    //         outstanding_mem_tag <= new_load      ? mem2proc_transaction_tag : 
    //                                mem_tag_match ? '0 : outstanding_mem_tag;
    //     end
    // end

    // stage_mem stage_mem_0 (
    //     // Inputs
    //     .ex_mem_reg      (ex_mem_reg),
    //     .Dmem_load_data  (mem2proc_data),

    //     // Outputs
    //     .mem_packet      (mem_packet),
    //     .Dmem_command    (Dmem_command),
    //     .Dmem_size       (Dmem_size),
    //     .Dmem_addr       (Dmem_addr),
    //     .Dmem_store_data (Dmem_store_data)
    // );

    // //////////////////////////////////////////////////
    // //                                              //
    // //           MEM/WB Pipeline Register           //
    // //                                              //
    // //////////////////////////////////////////////////

    // assign mem_wb_enable = 1'b1; // always enabled

    // always_ff @(posedge clock) begin
    //     if (reset || load_stall) begin
    //         mem_wb_inst_dbg <= `NOP; // debug output
    //         mem_wb_reg      <= 0;    // the defaults can all be zero!
    //     end else if (mem_wb_enable) begin
    //         mem_wb_inst_dbg <= ex_mem_inst_dbg; // debug output, just forwarded from EX
    //         mem_wb_reg      <= mem_packet;
    //     end
    // end

    // // debug outputs
    // assign mem_wb_NPC_dbg   = mem_wb_reg.NPC;
    // assign mem_wb_valid_dbg = mem_wb_reg.valid;

    // //////////////////////////////////////////////////
    // //                                              //
    // //                  WB-Stage                    //
    // //                                              //
    // //////////////////////////////////////////////////

    // stage_wb stage_wb_0 (
    //     // Input
    //     .mem_wb_reg (mem_wb_reg), // doesn't use all of these

    //     // Output
    //     .wb_packet (wb_packet)
    // );

    // // This signal is solely used by if_valid for the initial stalling behavior
    // always_ff @(posedge clock) begin
    //     if (reset) wb_valid <= 0;
    //     else       wb_valid <= mem_wb_reg.valid;
    // end

    // //////////////////////////////////////////////////
    // //                                              //
    // //               Pipeline Outputs               //
    // //                                              //
    // //////////////////////////////////////////////////

    // // Output the committed instruction to the testbench for counting
    // assign committed_insts[0] = wb_packet;

    /* Global controls*/
    logic flush;

    //////////////////////////////////////////////////
    //                                              //
    //                   Fetch                      //
    //                                              //
    //////////////////////////////////////////////////  

    fetch2decode f_2_decode;
    decode2fetch decode_2_f;

    stage_if_p4 fetch_0(
        .clock(clock),          // system clock
        .reset(reset),          // system reset
        //input     [1:0] if_valid,       // only go to next PC when true
        .flush(flush),
        .d_in   (decode_2_f),
        .d_out  (f_2_decode),
        .take_branch('0),    // taken-branch signal CHANGE!!!!!!
        .branch_target('0),  // target pc: use if take_branch is TRUE CHANGE!!!!!!
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

    dispatch dispatcher(
        .clock(clock),
        .reset(reset),

        .decode_in(de_2_disp),
        .decode_out(disp_2_de),

        .rs_in(rs_2_dispatch),
        .rs_out(dispatch_2_rs),

        .rob_in(rob_2_dispatch),
        .rob_out(dispatch_2_rob),

        .free_in(fl_2_dispatch),
        .free_out(dispatch_2_fl),

        .lsq_in('0),
        .lsq_out(),

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
    // TODO: collects from both rob2retire and btq2retire
    btq2retire btq_2_retire;
    retire2btq retire_2_btq;
    retire_final        retire_exec;
    logic [$clog2(`N):0] btq_rd_cnt;
    logic [$clog2(`N):0] allowed_retire_cnt; // FUCK ME
    logic mispred;
    logic mispred_target;
    always_comb begin
        mispred = 0;
        mispred_target = '0;
        btq_rd_cnt = 0;
        allowed_retire_cnt = 0;
        for (int unsigned i = 0; i < rob_2_retire.r_en_cnt; ++i) begin
            ++allowed_retire_cnt;
            if (!rob_2_retire.brch_vld[i])
                continue;

            if (btq_2_retire.pred[btq_rd_cnt] != btq_2_retire.take[btq_rd_cnt]) begin
                mispred = 1;
                mispred_target = btq_2_retire.tgt[btq_rd_cnt];
                // don't increment btq_rd_cnt — we're going to flush
                break;
            end 
            ++btq_rd_cnt;
        end

        retire_2_btq = '{
            rd_cnt : btq_rd_cnt
        };

        retire_exec = '{
            // only the count *may* be adjusted
            r_en_cnt    : allowed_retire_cnt,

            // the rest of the fields stay the same
            tag         : rob_2_retire.tag,
            t_old       : rob_2_retire.t_old,
            dst         : rob_2_retire.dst,
            halt        : rob_2_retire.halt,
            illegal     : rob_2_retire.illegal,
            brch_vld    : rob_2_retire.brch_vld
        };
    end

    always_ff @(posedge clock) begin
/* ======================================== */
        flush <= mispred;
/* ======================================== */
    end


    //////////////////////////////////////////////////
    //                                              //
    //           Branch target queue (BTQ)          //
    //                                              //
    //////////////////////////////////////////////////  
    execute2complete ex_2_complete;
    btq btq_0(
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .r_in (retire_2_btq),
        .r_out(btq_2_retire),
        .c_in(ex_2_complete),
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

        .c_in(ex_2_complete)
    );
    
    //////////////////////////////////////////////////
    //                                              //
    //                Re-Order Buffer               //
    //                                              //
    //////////////////////////////////////////////////  

    rob #(
        .ROB_SZ(`ROB_SZ),
        .N(`N)
    ) rob_0 (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .r_out      (rob_2_retire),
        .c_in       (ex_2_complete),
        .d_out      (rob_2_dispatch),
        .d_in       (dispatch_2_rob)
    );

    //////////////////////////////////////////////////
    //                                              //
    //                  Execute                     //
    //                                              //
    ////////////////////////////////////////////////// 

    
    stage_ex_p4 ex_0 (
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .rs_in(rs_2_ex),
        .rs_out(ex_2_rs),
        .c_out(ex_2_complete),
        .prf_out(prf_out),
        .prf_in(prf_in)
    );



    //////////////////////////////////////////////////
    //                                              //
    //                  Map Table                   //
    //                                              //
    //////////////////////////////////////////////////  

    map_table #(
        .N(`N)
    ) map_table_0 (
        .clock(clock),
        .reset(reset),
        .flush(flush),
        .c_in(ex_2_complete),
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
        .c_en   (ex_2_complete.c_en),
        .c_is_branch (ex_2_complete.is_branch),
        .c_ts   (ex_2_complete.c_ts),
        .c_vs   (ex_2_complete.c_data),

        // NOTE: Here each X_BY_FU type is coerced into a flat X array type
        .s_en1s (prf_out.s_en1s),
        .s_en2s (prf_out.s_en2s),
        .s_t1s  (prf_out.s_t1s),
        .s_t2s  (prf_out.s_t2s),
        .s_v1s  (prf_in.s_v1s),
        .s_v2s  (prf_in.s_v2s)
    );

    always_comb begin
        committed_insts = '0;
        foreach(committed_insts[i]) begin
            if (i >= retire_exec.r_en_cnt)
                continue;
            committed_insts[i].valid      = 1;
            committed_insts[i].halt       = retire_exec.halt[i];
            committed_insts[i].illegal    = retire_exec.illegal[i];
        end
    end


endmodule // pipeline
