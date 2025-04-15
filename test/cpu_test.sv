
/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  cpu_test.sv                                         //
//                                                                     //
//  Description :  Testbench module for the VeriSimpleV processor.     //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

// P4 TODO: Add your own debugging framework. Basic printing of data structures
//          is an absolute necessity for the project. You can use C functions 
//          like in test/pipeline_print.c or just do everything in verilog.
//          Be careful about running out of space on CAEN printing lots of state
//          for longer programs (alexnet, outer_product, etc.)

// These link to the pipeline_print.c file in this directory, and are used below to print
// detailed output to the pipeline_output_file, initialized by open_pipeline_output_file()
import "DPI-C" function string decode_inst(int inst);
//import "DPI-C" function void open_pipeline_output_file(string file_name);
//import "DPI-C" function void print_header();
//import "DPI-C" function void print_cycles(int clock_count);
//import "DPI-C" function void print_stage(int inst, int npc, int valid_inst);
//import "DPI-C" function void print_reg(int wb_data, int wb_idx, int wb_en);
//import "DPI-C" function void print_membus(int proc2mem_command, int proc2mem_addr,
//                                          int proc2mem_data_hi, int proc2mem_data_lo);
//import "DPI-C" function void close_pipeline_output_file();


`define TB_MAX_CYCLES 500
// `define TB_MAX_CYCLES 50000000


// Debug cycle limits, both inclusive
localparam DBG_CYCLE_MIN = 0;
localparam DBG_CYCLE_MAX = `TB_MAX_CYCLES;

module testbench;
    // string inputs for loading memory and output files
    // run like: cd build && ./simv +MEMORY=../programs/mem/<my_program>.mem +OUTPUT=../output/<my_program>
    // this testbench will generate 4 output files based on the output
    // named OUTPUT.{out cpi, wb, ppln} for the memory, cpi, writeback, and pipeline outputs.
    string program_memory_file, output_name;
    string out_outfile, cpi_outfile, writeback_outfile;//, pipeline_outfile;
    int out_fileno, cpi_fileno, wb_fileno; // verilog uses integer file handles with $fopen and $fclose

    // variables used in the testbench
    logic        clock;
    logic        reset;
    logic [31:0] clock_count; // also used for terminating infinite loops
    logic [31:0] instr_count;

    MEM_COMMAND proc2mem_command;
    ADDR        proc2mem_addr;
    MEM_BLOCK   proc2mem_data;
    MEM_TAG     mem2proc_transaction_tag;
    MEM_BLOCK   mem2proc_data;
    MEM_TAG     mem2proc_data_tag;
    MEM_SIZE    proc2mem_size;

    COMMIT_PACKET [`N-1:0] committed_insts;
    ADDR [`N-1:0] PC_reg;
    EXCEPTION_CODE error_status = NO_ERROR;

    DBG_btq         dbg_btq;
    DBG_fetch       dbg_fetch;
    DBG_decode      dbg_decode;
    DBG_dispatch    dbg_dispatch;
    DBG_lq          dbg_lq;
    DBG_mt          dbg_mt;
    DBG_prf         dbg_prf;
    DBG_rob         dbg_rob;
    DBG_rs          dbg_rs;
    DBG_sq          dbg_sq;
    DBG_retire      dbg_retire;

    // Instantiate the Pipeline
    cpu verisimpleV (
        // Inputs
        .clock (clock),
        .reset (reset),
        .mem2proc_transaction_tag (mem2proc_transaction_tag),
        .mem2proc_data            (mem2proc_data),
        .mem2proc_data_tag        (mem2proc_data_tag),

        // Outputs
        .proc2mem_command (proc2mem_command),
        .proc2mem_addr    (proc2mem_addr),
        .proc2mem_data    (proc2mem_data),
`ifndef CACHE_MODE
        .proc2mem_size    (proc2mem_size),
`endif

        .committed_insts (committed_insts),

        .dbg_btq        (dbg_btq),
        .dbg_fetch      (dbg_fetch),
        .dbg_decode     (dbg_decode),
        .dbg_dispatch   (dbg_dispatch),
        .dbg_lq         (dbg_lq),
        .dbg_mt         (dbg_mt),
        .dbg_prf        (dbg_prf),
        .dbg_rob        (dbg_rob),
        .dbg_rs         (dbg_rs),
        .dbg_sq         (dbg_sq),
        .dbg_retire     (dbg_retire)
    );


    // Instantiate the Data Memory
    mem memory (
        // Inputs
        .clock            (clock),
        .proc2mem_command (proc2mem_command),
        .proc2mem_addr    (proc2mem_addr),
        .proc2mem_data    (proc2mem_data),
`ifndef CACHE_MODE
        .proc2mem_size    (proc2mem_size),
`endif

        // Outputs
        .mem2proc_transaction_tag (mem2proc_transaction_tag),
        .mem2proc_data            (mem2proc_data),
        .mem2proc_data_tag        (mem2proc_data_tag)
    );


    // Generate System Clock
    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end


    initial begin
        $display("\n---- Starting CPU Testbench ----\n");

        // set paramterized strings, see comment at start of module
        if ($value$plusargs("MEMORY=%s", program_memory_file)) begin
            $display("Using memory file  : %s", program_memory_file);
        end else begin
            $display("Did not receive '+MEMORY=' argument. Exiting.\n");
            $finish;
        end
        if ($value$plusargs("OUTPUT=%s", output_name)) begin
            $display("Using output files : %s.{out, cpi, wb, ppln}", output_name);
            out_outfile       = {output_name,".out"}; // this is how you concatenate strings in verilog
            cpi_outfile       = {output_name,".cpi"};
            writeback_outfile = {output_name,".wb"};
            //pipeline_outfile  = {output_name,".ppln"};
        end else begin
            $display("\nDid not receive '+OUTPUT=' argument. Exiting.\n");
            $finish;
        end

        clock = 1'b0;
        reset = 1'b0;

        $display("\n  %16t : Asserting Reset", $realtime);
        reset = 1'b1;

        @(posedge clock);
        @(posedge clock);

        $display("  %16t : Loading Unified Memory", $realtime);
        // load the compiled program's hex data into the memory module
        $readmemh(program_memory_file, memory.unified_memory);

        @(posedge clock);
        @(posedge clock);
        #1; // This reset is at an odd time to avoid the pos & neg clock edges
        $display("  %16t : Deasserting Reset", $realtime);
        reset = 1'b0;

        wb_fileno = $fopen(writeback_outfile);
        $fdisplay(wb_fileno, "Register writeback output (hexadecimal)");

        // Open pipeline output file AFTER throwing the reset otherwise the reset state is displayed
        // open_pipeline_output_file(pipeline_outfile);
        // print_header();

        out_fileno = $fopen(out_outfile);

        $display("  %16t : Running Processor", $realtime);
    end

    // shadow ROB containing only debug info
    typedef struct packed {
        logic halt;
        logic illegal;
        ADDR NPC;
    } ROB_DEBUG_ENTRY;
    ROB_DEBUG_ENTRY rob_debug[int];

    always @(negedge clock) begin
        if (reset) begin
            // Count the number of cycles and number of instructions committed
            clock_count = 0;
            instr_count = 0;
        end else begin
            #2; // wait a short time to avoid a clock edge

            clock_count = clock_count + 1;

            if (clock_count % 10000 == 0) begin
                $display("  %16t : %d cycles", $realtime, clock_count);
            end

            // print the pipeline debug outputs via c code to the pipeline output file
            // print_cycles(clock_count - 1);
            // print_stage(if_inst_dbg,     if_NPC_dbg,     {31'b0,if_valid_dbg});
            // print_stage(if_id_inst_dbg,  if_id_NPC_dbg,  {31'b0,if_id_valid_dbg});
            // print_stage(id_ex_inst_dbg,  id_ex_NPC_dbg,  {31'b0,id_ex_valid_dbg});
            // print_stage(ex_mem_inst_dbg, ex_mem_NPC_dbg, {31'b0,ex_mem_valid_dbg});
            // print_stage(mem_wb_inst_dbg, mem_wb_NPC_dbg, {31'b0,mem_wb_valid_dbg});
            // print_reg(committed_insts[0].data, {27'b0,committed_insts[0].reg_idx},
            //           {31'b0,committed_insts[0].valid});
            // print_membus({30'b0,proc2mem_command}, proc2mem_addr[31:0],
            //              proc2mem_data[63:32], proc2mem_data[31:0]);

            `ifdef DEBUG
            print_custom_data();
            `endif

            output_reg_writeback_and_maybe_halt();

            `ifndef SYNTH
            // Add new dispatches to rob
            // TODO: Should this be cleared on branch mispredict?
            for (int i = 0, int cur_idx = 0; i < `N; ++i) begin
                if (i >= verisimpleV.rob_0.d_in.d_en_cnt)
                    break;
                cur_idx = verisimpleV.rob_0.comm_idxs[i];
                rob_debug[cur_idx] = '{
                    halt    : verisimpleV.rob_0.d_in.halt[i],
                    illegal : verisimpleV.rob_0.d_in.illegal[i],
                    NPC     : verisimpleV.rs_0.d_in.d_dat[i].NPC
                };
            end
            `endif // SYNTH

            // stop the processor
            if (error_status != NO_ERROR || clock_count > `TB_MAX_CYCLES) begin

                $display("  %16t : Processor Finished", $realtime);

                // close the writeback and pipeline output files
                // close_pipeline_output_file();
                $fclose(wb_fileno);

                // display the final memory and status
                show_final_mem_and_status(error_status);
                // output the final CPI
                output_cpi_file();

                $display("\n---- Finished CPU Testbench ----\n");
                
                $finish;
                // below: original. They put a #100 delay for some reason.
                // #100 $finish;
            end
        end // if(reset)
    end


    // Task to output register writeback data and potentially halt the processor.
    task output_reg_writeback_and_maybe_halt;
        ADDR pc;
        DATA inst;
        MEM_BLOCK block;
        logic illegal;
        logic halt;
        REG_IDX reg_idx;
        DATA data;

        /* V2: get retire data via hierarchial references
        NOTE: we only get writeback value debug output in simulation mode
        (only *.out is graded after all), since hierarchical references
        do not work in synthesis
        */
        `ifdef DEBUG
        $display("  %3d | >> cpu_test >>", $time);
        `endif // DEBUG
        for (int n = 0, int cur_idx = 0; n < `N; ++n) begin
            if (!committed_insts[n].valid)
                continue;
            // update the count for every committed instruction
            ++instr_count;
            halt    = committed_insts[n].halt;
            illegal = committed_insts[n].illegal;

            `ifndef SYNTH
            cur_idx = verisimpleV.rob_0.rtre_idxs[n];
            pc      = rob_debug[cur_idx].NPC - 4;
            block   = memory.unified_memory[pc[31:3]];
            inst    = block.word_level[pc[2]];
            reg_idx = verisimpleV.rob_0.r_out.entries[n].dst;
            data    = verisimpleV.prf_0.file[
                verisimpleV.rob_0.r_out.entries[n].tag
            ];
            // print the committed instructions to the writeback output file
            if (reg_idx == `ZERO_REG) begin
                $fdisplay(wb_fileno, "PC %4x:%-8s| ---", pc, decode_inst(inst));
            end else begin
                $fdisplay(wb_fileno, "PC %4x:%-8s| r%02d=%-8x",
                          pc,
                          decode_inst(inst),
                          reg_idx,
                          data);
            end
            rob_debug.delete(cur_idx);
            `ifdef DEBUG
            $display("commit[%0d]: (pc: 0x%x, inst: 0x%x) vld: %b, halt: %b, illegal: %b",
                n,
                pc,
                inst,
                committed_insts[n].valid,
                committed_insts[n].halt,
                committed_insts[n].illegal
            );
            `endif // DEBUG

            `endif // SYNTH

            // exit if we have an illegal instruction or a halt
            if (illegal) begin
                error_status = ILLEGAL_INST;
                break;
            end else if(halt) begin
                error_status = HALTED_ON_WFI;
                break;
            end
        end
        `ifdef DEBUG
        $display("  %3d | << cpu_test <<", $time);
        `endif // SYNTH

        // V1: original
        // for (int n = 0; n < `N; ++n) begin
        //     if (committed_insts[n].valid) begin
        //         // update the count for every committed instruction
        //         instr_count = instr_count + 1;

        //         pc = committed_insts[n].NPC - 4;
        //         block = memory.unified_memory[pc[31:3]];
        //         inst = block.word_level[pc[2]];
        //         // print the committed instructions to the writeback output file
        //         if (committed_insts[n].reg_idx == `ZERO_REG) begin
        //             $fdisplay(wb_fileno, "PC %4x:%-8s| ---", pc, decode_inst(inst));
        //         end else begin
        //             $fdisplay(wb_fileno, "PC %4x:%-8s| r%02d=%-8x",
        //                       pc,
        //                       decode_inst(inst),
        //                       committed_insts[n].reg_idx,
        //                       committed_insts[n].data);
        //         end

        //         // exit if we have an illegal instruction or a halt
        //         if (committed_insts[n].illegal) begin
        //             error_status = ILLEGAL_INST;
        //             break;
        //         end else if(committed_insts[n].halt) begin
        //             error_status = HALTED_ON_WFI;
        //             break;
        //         end
        //     end // if valid
        // end
    endtask // task output_reg_writeback_and_maybe_halt


    // Task to output the final CPI and # of elapsed clock edges
    task output_cpi_file;
        real cpi;
        begin
            cpi = $itor(clock_count) / instr_count; // must convert int to real
            cpi_fileno = $fopen(cpi_outfile);
            $fdisplay(cpi_fileno, "@@@  %0d cycles / %0d instrs = %f CPI",
                      clock_count, instr_count, cpi);
            $fdisplay(cpi_fileno, "@@@  %4.2f ns total time to execute",
                      clock_count * `CLOCK_PERIOD);
            $fclose(cpi_fileno);
        end
    endtask // task output_cpi_file


    // Show contents of Unified Memory in both hex and decimal
    // Also output the final processor status
    task show_final_mem_and_status;
        input EXCEPTION_CODE final_status;
        int showing_data;
        begin
            $fdisplay(out_fileno, "\nFinal memory state and exit status:\n");
            $fdisplay(out_fileno, "@@@ Unified Memory contents hex on left, decimal on right: ");
            $fdisplay(out_fileno, "@@@");
            showing_data = 0;
            for (int k = 0; k <= `MEM_64BIT_LINES - 1; k = k+1) begin
                if (memory.unified_memory[k] != 0) begin
                    $fdisplay(out_fileno, "@@@ mem[%5d] = %x : %0d", k*8, memory.unified_memory[k],
                                                             memory.unified_memory[k]);
                    showing_data = 1;
                end else if (showing_data != 0) begin
                    $fdisplay(out_fileno, "@@@");
                    showing_data = 0;
                end
            end
            $fdisplay(out_fileno, "@@@");

            case (final_status)
                LOAD_ACCESS_FAULT: $fdisplay(out_fileno, "@@@ System halted on memory error");
                HALTED_ON_WFI:     $fdisplay(out_fileno, "@@@ System halted on WFI instruction");
                ILLEGAL_INST:      $fdisplay(out_fileno, "@@@ System halted on illegal instruction");
                default:           $fdisplay(out_fileno, "@@@ System halted on unknown error code %x", final_status);
            endcase
            $fdisplay(out_fileno, "@@@");
            $fclose(out_fileno);
        end
    endtask // task show_final_mem_and_status



    // OPTIONAL: Print our your data here
    // It will go to the $program.log file
    function print_id_result(input ID_RESULT x);
        $display("ID_RESULT: id=%3d t=%2d t1=%2d t2=%2d t1_rdy=%b t2_rdy=%b fu_idx=%2d rob_idx=%2d btq_idx=%2d sq_idx=%2d lq_idx=%2d is_brch:%b inst=%h PC=%h NPC=%h opa_select=%1d opb_select=%1d dest_reg_idx=%2d alu_func=%1d mult=%b rd_mem=%b wr_mem=%b cond_branch=%b uncond_branch=%b halt=%b illegal=%b csr_op=%b",
            x.id,
            x.t,
            x.t1,
            x.t2,
            x.t1_rdy,
            x.t2_rdy,
            x.fu_idx,
            x.rob_idx,
            x.btq_idx,
            x.sq_idx,
            x.lq_idx,
            x.is_brch,
            x.inst,
            x.PC,
            x.NPC,
            x.opa_select,
            x.opb_select,
            x.dest_reg_idx,
            x.alu_func,
            x.mult,
            x.rd_mem,
            x.wr_mem,
            x.cond_branch,
            x.uncond_branch,
            x.halt,
            x.illegal,
            x.csr_op
        );
    endfunction

    function get_fu_name(input FU_IDX fu_idx, output string name);
        case (fu_idx)
            FU_ALU:     name = "ALU";
            FU_MULT:    name = "MULT";
            FU_LOAD:    name = "LOAD";
            FU_STORE:   name = "STORE";
            default:    name = "Unknown FU";
        endcase
    endfunction

    task print_btq;
        // internal state
        BTQ_ENTRY [`BTQ_SZ-1:0]      state;
        logic [$clog2(`BTQ_SZ)-1:0]  head;
        logic [$clog2(`BTQ_SZ)-1:0]  tail;
        logic [$clog2(`BTQ_SZ):0]    used;
        // I/O
        retire2btq           r_in;
        btq2retire           r_out;
        execute2complete_dat cdat_in;
        dispatch2btq         d_in;
        btq2dispatch         d_out;

        state   = dbg_btq.state;
        head    = dbg_btq.head;
        tail    = dbg_btq.tail;
        used    = dbg_btq.used;
        r_in    = dbg_btq.r_in;
        r_out   = dbg_btq.r_out;
        cdat_in = dbg_btq.cdat_in;
        d_in    = dbg_btq.d_in;
        d_out   = dbg_btq.d_out;

        $display(">> BTQ >>");
        for (int i = 0; i < `BTQ_SZ; ++i) begin
            $display("BTQ [%0d]: tgt: %x, NPC: %x, pred: %b, take: %b%s", 
                i,
                state[i].tgt,
                state[i].NPC,
                state[i].pred,
                state[i].take,
                (i == head && head == tail) 
                    ? " << h/t"
                    : (i == head) 
                        ? " << h" 
                        : (i == tail)
                            ? " << t"
                            : ""
            );
            if (i == tail)
                break;
        end

        for (int i = 0; i < `N; ++i) begin
            $display("cdat_in[%0d]: c_en: %b, is_brch: %b, c_btq_idxs: %d, take: %b", 
                i,
                cdat_in.en[i],
                cdat_in.is_brch[i],
                cdat_in.btq_idxs[i],
                cdat_in.take[i]
            );
        end
        $display("r_in: rd_cnt %d", r_in.rd_cnt);
        $display("r_out: used_scnt: %0d", r_out.used_scnt);
        for (int i = 0; i < `N; ++i) begin
            $display("r_out[%d]: tgt: %x, NPC: %x, pred: %b, take: %b", 
                i,
                r_out.dat[i].tgt,
                r_out.dat[i].NPC,
                r_out.dat[i].pred,
                r_out.dat[i].take
            );
        end
        $display("<< BTQ <<");
    endtask

    task print_icache();
        DBG_icache dbg_icache;

        // internal state
        logic changed_addr;
        logic [12-`ICACHE_LINE_BITS:0] current_tag,   last_tag,   write_tag;
        logic [`ICACHE_LINE_BITS -1:0] current_index, last_index, write_index;
        logic                          got_mem_data;
        MSHR_entry [15:0] MSHR;
        ICACHE_TAG [`ICACHE_LINES-1:0] icache_tags;
        // I/O
        MEM_TAG   Imem2proc_transaction_tag;
        MEM_BLOCK Imem2proc_data;
        MEM_TAG   Imem2proc_data_tag;
        ADDR proc2Icache_addr;
        MEM_COMMAND proc2Imem_command;
        ADDR        proc2Imem_addr;
        MEM_BLOCK Icache_data_out;
        logic     Icache_valid_out;

        dbg_icache = dbg_fetch.dbg_icache;
        changed_addr                = dbg_icache.changed_addr;
        current_tag                 = dbg_icache.current_tag;
        last_tag                    = dbg_icache.last_tag;
        write_tag                   = dbg_icache.write_tag;
        current_index               = dbg_icache.current_index;
        last_index                  = dbg_icache.last_index;
        write_index                 = dbg_icache.write_index;
        got_mem_data                = dbg_icache.got_mem_data;
        MSHR                        = dbg_icache.MSHR;
        icache_tags                 = dbg_icache.icache_tags;
        // I/O
        Imem2proc_transaction_tag   = dbg_icache.Imem2proc_transaction_tag;
        Imem2proc_data              = dbg_icache.Imem2proc_data;
        Imem2proc_data_tag          = dbg_icache.Imem2proc_data_tag;
        proc2Icache_addr            = dbg_icache.proc2Icache_addr;
        proc2Imem_command           = dbg_icache.proc2Imem_command;
        proc2Imem_addr              = dbg_icache.proc2Imem_addr;
        Icache_data_out             = dbg_icache.Icache_data_out;
        Icache_valid_out            = dbg_icache.Icache_valid_out;

        $display("  | >> ICACHE >>", $time);
        $display("tags: {cur: %x, last: %x, wr: %x}", current_tag, last_tag, write_tag);
        $display("read: {en %b, addr: %x, data: %x}", 1'b1, current_index, Icache_data_out);
        $display("writ: {en %b, addr: %x, data: %x}", got_mem_data, write_index, Imem2proc_data);
        $display("changed_addr: %b, proc2Imem_command: %1d, proc2Imem_addr: %x", changed_addr, proc2Imem_command, proc2Imem_addr);
        $display("last: {tag: %x, idx: %x} -> curr {tag: %x, idx: %x} <changed: %b>", last_tag, last_index, current_tag, current_index, changed_addr);
        $display("  | << ICACHE <<", $time);
    endtask

    task print_fetch;
        logic           flush;
        decode2fetch    d_in;
        fetch2decode    d_out;
        retire2fetch    r_in;
        MEM_BLOCK [1:0] Imem_data;
        ADDR [`N-1:0]   PC_reg;

        flush       = dbg_fetch.flush;
        d_in        = dbg_fetch.d_in;
        d_out       = dbg_fetch.d_out;
        r_in        = dbg_fetch.r_in;
        Imem_data   = dbg_fetch.Imem_data;
        PC_reg      = dbg_fetch.PC_reg;

        $display(">> Fetch >>");
        $display("r_in: {flush: %b, corrected_PC: 0x%x}", flush, r_in.corrected_PC);
        $display("PC_reg:  %x", PC_reg);
        $display("Imem_data: %x", Imem_data);
        $display("<< Fetch <<");
    endtask

    task print_decode;
        fetch2decode    f_in;
        decode2fetch    f_out;
        dispatch2decode d_in;
        decode2dispatch d_out;

        f_in    = dbg_decode.f_in;
        f_out   = dbg_decode.f_out;
        d_in    = dbg_decode.d_in;
        d_out   = dbg_decode.d_out;

        $display(">> ID >>", $time);
        // $display("  %3d | FIFO: {used_scnt: %d, free_scnt: %d}",
        //     $time,
        //     used_scnt,
        //     free_scnt
        // );
        $display("f_in:  {f_en_cnt: %d, PC: [%x, %x], inst: [%x, %x]}",
            f_in.f_en_cnt,
            f_in.f_en_cnt > 0 ? f_in.f_dat[0].PC : 0,
            f_in.f_en_cnt > 1 ? f_in.f_dat[1].PC : 0,
            f_in.f_en_cnt > 0 ? f_in.f_dat[0].inst : 0,
            f_in.f_en_cnt > 1 ? f_in.f_dat[1].inst : 0,
        );

        $display("d_out: {d_en_cnt: %d, PC: [%x, %x], inst: [%x, %x]}",
            d_in.dispatch_en_cnt,
            d_out.d_dat[0].PC, 
            d_out.d_dat[1].PC,
            d_out.d_dat[0].inst, 
            d_out.d_dat[1].inst
        );
        print_id_result(d_out.d_dat[0]);
        print_id_result(d_out.d_dat[1]);
        // $display("d_out.d_dat[0]: %b", d_out.d_dat[0]);
        // $display("d_out.d_dat[1]: %b", d_out.d_dat[1]);
        $display("<< ID <<", $time);
    endtask

    task print_dispatch;
        decode2dispatch       decode_in;
        dispatch2decode       decode_out;
        rs2dispatch           rs_in;
        dispatch2rs           rs_out;
        rob2dispatch          rob_in;
        dispatch2rob          rob_out;
        free_list2dispatch    free_in;
        dispatch2free_list    free_out;
        sq2dispatch           sq_in;
        dispatch2sq           sq_out;
        btq2dispatch          btq_in;
        dispatch2btq          btq_out;
        execute2complete_tag  ctag_in;
        map_table2dispatch    map_in;
        dispatch2map_table    map_out;

        decode_in  = dbg_dispatch.decode_in;
        decode_out = dbg_dispatch.decode_out;
        rs_in      = dbg_dispatch.rs_in;
        rs_out     = dbg_dispatch.rs_out;
        rob_in     = dbg_dispatch.rob_in;
        rob_out    = dbg_dispatch.rob_out;
        free_in    = dbg_dispatch.free_in;
        free_out   = dbg_dispatch.free_out;
        sq_in      = dbg_dispatch.sq_in;
        sq_out     = dbg_dispatch.sq_out;
        btq_in     = dbg_dispatch.btq_in;
        btq_out    = dbg_dispatch.btq_out;
        ctag_in    = dbg_dispatch.ctag_in;
        map_in     = dbg_dispatch.map_in;
        map_out    = dbg_dispatch.map_out;

        $display("  %3d | >> Dispatch >>", $time);
        $display("r_in.btq_rdy_scnt: %d",   btq_in.btq_rdy_scnt);
        $display("btq_in.btq_rdy_scnt: %d",   btq_in.btq_rdy_scnt);
        $display("rob_in.rob_rdy_scnt: %d",  rob_in.rob_rdy_scnt);
        $display("decode_in.d_vld_scnt: %d",  decode_in.d_vld_scnt);
        $display("free_in.free_rdy_scnt: %d",  free_in.free_rdy_scnt);
        $display("decode_in.prvw_has_dests: %b", decode_in.prvw_has_dests);
        $display("  %3d | << Dispatch <<", $time);
    endtask

    task print_map_table();
        struct packed {
            PHYS_REG_IDX t;
        } [`NUM_ARCH_REG-1:0] entries;
        arch_map2map_table am_in;
        dispatch2map_table d_in;
        map_table2dispatch d_out;

        entries = dbg_mt.entries;
        am_in   = dbg_mt.am_in;
        d_in    = dbg_mt.d_in;
        d_out   = dbg_mt.d_out;

        $display(">> MT >>", $time);
        $display("dis_in:   {en_cnt: %d, [(%0d->%0d, %d, %d), (%0d->%0d, %d, %d)]}",
            d_in.en_cnt,
            d_in.dsts[0],
            d_in.ts[0],
            d_in.src1s[0],
            d_in.src2s[0],
            d_in.dsts[1],
            d_in.ts[1],
            d_in.src1s[1],
            d_in.src2s[1]
        );
        $display("dis_out:  {en_cnt: %d, [(told: %0d, t1: %0d, t2: %0d), (told: %0d, t1: %0d, t2: %0d)]}",
            d_in.en_cnt,
            d_out.ts_old[0],
            d_out.t1s[0],
            d_out.t2s[0],

            d_out.ts_old[1],
            d_out.t1s[1],
            d_out.t2s[1]
        );
        $display("<< MT <<", $time);

    endtask

    task print_prf;
        logic [`PHYS_REG_SZ_R10K-1:0][$bits(DATA)-1:0] file;
        execute2complete_dat cdat_in;
        execute2prf ex_in;
        prf2execute ex_out;

        file    = dbg_prf.file;
        cdat_in = dbg_prf.cdat_in;
        ex_in   = dbg_prf.ex_in;
        ex_out  = dbg_prf.ex_out;
    endtask

    task print_rob;
        ROB_ENTRY [`ROB_SZ-1:0]     state;
        logic [$clog2(`ROB_SZ)-1:0]  head;
        logic [$clog2(`ROB_SZ)-1:0]  tail;
        logic [$clog2(`ROB_SZ):0]   used;
        logic [$clog2(`ROB_SZ):0]   free;
        logic [$clog2(4*`N):0]      rsvd;
        // I/O
        rob2retire  r_out;
        retire_final r_in;
        execute2complete_dat cdat_in;
        rob2dispatch d_out;
        dispatch2rob d_in;

        state   = dbg_rob.state;
        head    = dbg_rob.head;
        tail    = dbg_rob.tail;
        used    = dbg_rob.used;
        free    = dbg_rob.free;
        rsvd    = dbg_rob.rsvd;

        r_out   = dbg_rob.r_out;
        r_in    = dbg_rob.r_in;
        cdat_in = dbg_rob.cdat_in;
        d_out   = dbg_rob.d_out;
        d_in    = dbg_rob.d_in;

        $display("  | >> ROB >>");
        $display("r_out: en_cnt: %d", r_out.r_vld_cnt);
        for (int i = 0; i < `N; ++i) begin
            $display("r_out[%d]: tag: %d, t_old: %d, dst: %d, halt: %d, illegal: %d, is_brch: %d",
                i,
                r_out.entries[i].tag,
                r_out.entries[i].t_old,
                r_out.entries[i].dst,
                r_out.entries[i].halt,
                r_out.entries[i].illegal,
                r_out.entries[i].is_brch
            );
        end

        for (int i = 0; i < `ROB_SZ; ++i) begin
            $display("Rob[%2d]: cpl %b, t: %2d, t_old: %2d, dst: %2d, is_brch: %b, wr_mem: %b, rd_mem: %b, halt: %0b, illegal: %0b%s",
                i,
                state[i].cpl,
                state[i].tag,
                state[i].t_old,
                state[i].dst,
                state[i].is_brch,
                state[i].wr_mem,
                state[i].rd_mem,
                state[i].halt,
                state[i].illegal,
                (i == head && head == tail) 
                    ? " << h/t"
                    : (i == head) 
                        ? " << h" 
                        : (i == tail)
                            ? " << t"
                            : ""
            );

            if (i == tail)
                break;
        end
        $display("  | << ROB <<");

    endtask

    task print_rs;
        // internal state
        RS_ENTRY [`RS_SZ-1:0] entries; // ms1 test: remove one RS entry (caught)
        // I/O
        dispatch2rs d_in;
        rs2dispatch d_out;
        execute2rs  ex_in;
        rs2execute  ex_out;
        execute2complete_tag ctag_in;

        entries = dbg_rs.entries;
        d_in    = dbg_rs.d_in;
        d_out   = dbg_rs.d_out;
        ex_in   = dbg_rs.ex_in;
        ex_out  = dbg_rs.ex_out;
        ctag_in = dbg_rs.ctag_in;

        $display("  | >> RS >>");
        print_id_result(d_in.d_dat[0]);
        print_id_result(d_in.d_dat[1]);
        for (int i = 0; i < `RS_SZ; ++i) begin
            string fu_name;
            get_fu_name(entries[i].dat.fu_idx, fu_name);

            if (!entries[i].busy) begin
                $display("Entry [%2d]:", i);
                continue;
            end

            $display("Entry [%2d]: pc=0x%x, id=%3d (%x), busy=%b, issued=%b, t=%2d, t1=%2d, t2=%2d, t1_rdy=%b, t2_rdy=%b, fu=%s(%2d), sq_idx=%0d",
                i, 
                entries[i].dat.PC,
                entries[i].dat.id, 
                entries[i].dat.inst,
                entries[i].busy, 
                entries[i].issued, 
                entries[i].dat.t, 
                entries[i].dat.t1, 
                entries[i].dat.t2, 
                entries[i].dat.t1_rdy, 
                entries[i].dat.t2_rdy, 
                
                entries[i].busy ? fu_name : "*",
                entries[i].dat.fu_idx,
                entries[i].dat.sq_idx
            );
        end
        $display("  | << RS <<");

    endtask

    task print_sq;
        // internal state
        SQ_ENTRY [`LSQ_SZ-1:0]      state;
        logic [$clog2(`LSQ_SZ)-1:0] head;
        logic [$clog2(`LSQ_SZ)-1:0] ret_head;
        logic [$clog2(`LSQ_SZ)-1:0] tail;
        logic [$clog2(`LSQ_SZ):0]   used;
        // I/O

        dispatch2sq   dis_2_sq;
        execute2sq    exec_2_sq;
        retire2sq     retire_2_sq;
        MEM_TAG       mem2proc_transaction_tag;

        sq2dispatch  sq_2_dis;
        sq2execute   sq_2_exec;
        // sq2rs sq_2_rs,
        sq2retire    sq_2_retire;
        stRET2mem    ret_2_mem;

        state   = dbg_sq.state;
        head    = dbg_sq.head;
        ret_head= dbg_sq.ret_head;
        tail    = dbg_sq.tail;
        used    = dbg_sq.used;

        dis_2_sq    = dbg_sq.dis_2_sq;
        exec_2_sq   = dbg_sq.exec_2_sq;
        retire_2_sq = dbg_sq.retire_2_sq;
        mem2proc_transaction_tag = dbg_sq.mem2proc_transaction_tag;

        sq_2_dis    = dbg_sq.sq_2_dis;
        sq_2_exec   = dbg_sq.sq_2_exec;
        sq_2_retire = dbg_sq.sq_2_retire;
        ret_2_mem   = dbg_sq.ret_2_mem;

        $display("  | >> SQ");
        $display("RET_HEAD: %0d", ret_head);
        for (int i = 0; i < `LSQ_SZ; i++) begin
            $display("Entry [%2d]: sq_idx=%2d, rob_idx=%2d, addr=%4x, data=%x, d_valid=%b, addr mask=%4b%s",
            i,
            state[i].sq_idx,
            state[i].rob_idx,
            state[i].addr,
            state[i].data,
            state[i].d_vld,
            // state[i].bytewise_addr,
            state[i].bytewise_addr_mask,
                (i == head && head == tail) 
                    ? " << h/t"
                    : (i == head) 
                        ? " << h" 
                        : (i == tail)
                            ? " << t"
                            : ""
            );
        end
        $display("  | << SQ");
    endtask

    task print_lq;
        // internal state
        LQ_ENTRY [`LSQ_SZ-1:0]      state;
        logic [$clog2(`LSQ_SZ)-1:0] head;
        logic [$clog2(`LSQ_SZ)-1:0] tail;
        logic [$clog2(`LSQ_SZ):0]   used;
        // I/O

        dispatch2lq   dis_2_lq;
        execute2lq    exec_2_lq;
        retire2lq     retire_2_lq;

        lq2dispatch  lq_2_dis;

        state   = dbg_lq.state;
        head    = dbg_lq.head;
        tail    = dbg_lq.tail;
        used    = dbg_lq.used;

        dis_2_lq    = dbg_lq.dis_2_lq;
        exec_2_lq   = dbg_lq.exec_2_lq;
        retire_2_lq = dbg_lq.retire_2_lq;

        lq_2_dis    = dbg_lq.lq_2_dis;

        $display("  | >> LQ");
        for (int i = 0; i < `LSQ_SZ; i++) begin
            $display("Entry [%2d]: sq_idx=%2d, PC=%2d, addr=%4x, d_valid=%b, err_ld_ooo=%b%s",
            i,
            state[i].sq_idx,
            state[i].inst_pc,
            state[i].addr,
            state[i].d_vld,
            state[i].err_ld_ooo,
                (i == head && head == tail) 
                    ? " << h/t"
                    : (i == head) 
                        ? " << h" 
                        : (i == tail)
                            ? " << t"
                            : ""
            );
        end
        $display("  | << LQ");
    endtask

    task print_retbuf;
        DBG_retbuf dbg_retbuf;
        // internal state
        SQ_ENTRY [`LSQ_SZ-1:0]     state;
        logic [$clog2(`LSQ_SZ)-1:0] head;
        logic [$clog2(`LSQ_SZ)-1:0] tail;
        logic [$clog2(`LSQ_SZ):0]   used;
        // I/O
        sq2stRET sq_2_ret;
        MEM_TAG mem2proc_transaction_tag;
        stRET2sq ret_2_sq;
        forwardRET2sq forward_ret_2_sq;
        stRET2mem ret_2_mem;

        dbg_retbuf = dbg_sq.dbg_retbuf;
        state   = dbg_retbuf.state;
        head    = dbg_retbuf.head;
        tail    = dbg_retbuf.tail;
        used    = dbg_retbuf.used;

        sq_2_ret                 = dbg_retbuf.sq_2_ret;
        mem2proc_transaction_tag = dbg_retbuf.mem2proc_transaction_tag;
        ret_2_sq                 = dbg_retbuf.ret_2_sq;
        forward_ret_2_sq         = dbg_retbuf.forward_ret_2_sq;
        ret_2_mem                = dbg_retbuf.ret_2_mem;

        $display("  >> RET buffer");
        for (int i = 0; i < `SQ_RET_BUF_SZ; i++) begin
            $display("Entry [%2d]: sq_idx=%2d, rob_idx=%2d, addr=%4x, data=%x, d_valid=%b%s",
            i,
            state[i].sq_idx,
            state[i].rob_idx,
            state[i].addr,
            state[i].data,
            state[i].d_vld,
                (i == head && head == tail) 
                    ? " << h/t"
                    : (i == head) 
                        ? " << h" 
                        : (i == tail)
                            ? " << t"
                            : ""
            );
        end
        $display("  | << RET buffer");

    endtask

    task print_retire;
        rob2retire rob_in;
        btq2retire btq_in;
        retire2btq btq_out;
        sq2retire sq_in;
        retire2sq sq_out;
        lq2retire lq_in;
        logic mispred;
        ADDR  mispred_target;
        retire_final retire_exec;

        rob_in         = dbg_retire.rob_in;
        btq_in         = dbg_retire.btq_in;
        btq_out        = dbg_retire.btq_out;
        sq_in          = dbg_retire.sq_in;
        sq_out         = dbg_retire.sq_out;
        lq_in          = dbg_retire.lq_in;
        mispred        = dbg_retire.mispred;
        mispred_target = dbg_retire.mispred_target;
        retire_exec    = dbg_retire.retire_exec;

        $display("  | >> retire >>");
        for (int i = 0; i < `N; ++i) begin
            $display("btq_out [%0d]: tgt: %x, NPC: %x, pred: %b, take: %b", 
                i,
                btq_in.dat[i].tgt,
                btq_in.dat[i].NPC,
                btq_in.dat[i].pred,
                btq_in.dat[i].take
            );
        end
        $display("btq_rd_cnt: %0d", btq_out.rd_cnt);

        for (int i = 0; i < `N; ++i) begin
            $display("lq_in [%2d]: PC: %x, err_ld_ooo: %b",
                i,
                lq_in.PC[i],
                lq_in.err_ld_ooo[i]
            );
        end

        $display("retire_exec.r_en_cnt: %0d", retire_exec.r_en_cnt);
        $display("  | << retire <<");
    endtask


    task print_custom_data;
        int cycle_no;
        cycle_no = clock_count - 1;

        if (cycle_no < DBG_CYCLE_MIN)
            return;
        if (cycle_no > DBG_CYCLE_MAX)
            return;

        $display("  | >> CYCLE: %3d (t: %3d)", clock_count-1, $time);
        print_btq();
        print_fetch();
        print_icache();
        print_decode();
        print_dispatch();
        print_map_table();
        print_prf();
        print_rob();
        print_rs();
        print_sq();
        print_retbuf();
        print_lq();
        print_retire();
        $display("  | << CYCLE: %3d (t: %3d)", clock_count-1, $time);
    endtask


endmodule // module testbench
