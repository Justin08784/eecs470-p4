
/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  cpu_test.sv                                         //
//                                                                     //
//  Description :  Testbench module for the VeriSimpleV processor.     //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"
`include "dcache_block_direct.svh"
`include "execute.svh"
`include "ISA.svh"

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


`define TB_MAX_CYCLES 50000000
// `define TB_MAX_CYCLES 500
// `define TB_MAX_CYCLES 10000


// Debug cycle limits, both inclusive
localparam DBG_CYCLE_MIN = 0;
localparam DBG_CYCLE_MAX = `TB_MAX_CYCLES;
// localparam DBG_CYCLE_MIN = 1480;
// localparam DBG_CYCLE_MAX = 1510;
// localparam DBG_CYCLE_MIN = 1300;
// localparam DBG_CYCLE_MAX = 1500;

/*
- unsure about correctness of call/ret checking; make sure to
test thoroughly with progs with function calls
- TODO: move this to icache refill path and store the 4 bits in
the icache metadata
*/
module predecoder (
    input  INST     inst,

    output logic    call,
    output logic    ret,
    output logic    cond_branch,
    output logic    uncond_branch
);
    always_comb begin
        REG_IDX rd;
        call            = `FALSE;
        ret             = `FALSE;
        cond_branch     = `FALSE;
        uncond_branch   = `FALSE;
        rd = inst.r.rd;

        casez (inst)
            `RV32_JAL: begin
                uncond_branch = `TRUE;
                call = (rd == 5'd1) || (rd == 5'd5);
            end

            `RV32_JALR: begin
                uncond_branch = `TRUE;
                call = (rd == 5'd1) || (rd == 5'd5);
                ret  = (rd         == `ZERO_REG)    &&
                       (inst.r.rs1 == 5'd1)         &&   // rs1 lives in same bit‑slice for I‑type
                       (inst.i.imm == 12'd0);
            end

            `RV32_BEQ, `RV32_BNE, `RV32_BLT, `RV32_BGE,
            `RV32_BLTU, `RV32_BGEU: begin
                cond_branch = `TRUE;
                // stage_ex uses inst.b.funct3 as the branch function
            end
            default:;
        endcase // casez (inst)
    end // always
endmodule // predecoder

module testbench;
    // string inputs for loading memory and output files
    // run like: cd build && ./simv +MEMORY=../programs/mem/<my_program>.mem +OUTPUT=../output/<my_program>
    // this testbench will generate 4 output files based on the output
    // named OUTPUT.{out cpi, wb, ppln} for the memory, cpi, writeback, and pipeline outputs.
    string program_memory_file, output_name;
    string out_outfile, cpi_outfile, writeback_outfile;//, pipeline_outfile;
    int out_fileno, cpi_fileno, wb_fileno; // verilog uses integer file handles with $fopen and $fclose

    // variables used in the testbench
    logic        print_en;
    logic        clock;
    logic        reset;
    logic [31:0] clock_count; // also used for terminating infinite loops
    logic [31:0] instr_count;

    fetch2mem   f2mem;
    mem2fetch   mem2f;

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

    DBG_dcache      dbg_dcache;

    // Instantiate the Pipeline
    cpu verisimpleV (
        // Inputs
        .clock (clock),
        .reset (reset),

        .f2mem  (f2mem),
        .mem2f  (mem2f),

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

        .dbg_dcache     (dbg_dcache),
        .committed_insts(committed_insts)
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

    always_comb begin
        for (int i = 0; i < `N; ++i)
            mem2f.data[i] = memory.unified_memory[addr2dw(f2mem.PCs[i])];
    end

    generate
    for (genvar blk = 0; blk < `N; ++blk) begin : gen_predecs
        for (genvar woff = 0; woff < 2; ++woff) begin
            predecoder predec_i (
                .inst           (mem2f.data[blk].word_level[woff]),

                .call           (mem2f.insn_md[blk][woff].call),
                .ret            (mem2f.insn_md[blk][woff].ret),
                .cond_branch    (mem2f.insn_md[blk][woff].cond_branch),
                .uncond_branch  (mem2f.insn_md[blk][woff].uncond_branch)
            );
        end
    end
    endgenerate

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
`ifdef DEBUG
        int   id;
`endif
        FU_IDX fu_idx;
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
            print_en = (DBG_CYCLE_MIN <= clock_count-1) && (clock_count-1 <= DBG_CYCLE_MAX);
            /* Provided delay <revert if necessary> */
            // #2; // wait a short time to avoid a clock edge
            /* Our delay */
            #0; // wait a short time to avoid a clock edge

            clock_count = clock_count + 1;

            if (clock_count % 10000 == 0) begin
                $display("  %16t : %d cycles", $realtime, clock_count);
            end
`ifdef DEBUG
            print_custom_data();
`endif
            output_reg_writeback_and_maybe_halt();

`ifndef SYNTH
            // Add new dispatches to rob
            // TODO: Should this be cleared on branch mispredict?
            for (int i = 0, int cur_idx = 0; i < `N; ++i) begin
                if (i >= verisimpleV.rob0.d_in.d_en_cnt)
                    break;
                cur_idx = verisimpleV.rob0.comm_idxs[i];
                rob_debug[cur_idx] = '{
`ifdef DEBUG
                    id      : verisimpleV.rs0.d_in.dat[i].id,
`endif
                    halt    : verisimpleV.rob0.d_in.halt[i],
                    illegal : verisimpleV.rob0.d_in.illegal[i],
                    fu_idx  : verisimpleV.rob0.d_in.fu_idx[i],
                    NPC     : w2addr(verisimpleV.rs0.d_in.dat[i].PC + 1)
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
        int id;
        DATA inst;
        MEM_BLOCK block;
        logic illegal;
        logic halt;
        REG_IDX reg_idx;
        PHYS_REG_IDX tag, t_old;
        DATA data;

        /* V2: get retire data via hierarchial references
        NOTE: we only get writeback value debug output in simulation mode
        (only *.out is graded after all), since hierarchical references
        do not work in synthesis
        */
        for (int n = 0, int cur_idx = 0; n < `N; ++n) begin
            if (!committed_insts[n].valid)
                continue;
            // update the count for every committed instruction
            ++instr_count;
            halt    = committed_insts[n].halt;
            illegal = committed_insts[n].illegal;

`ifndef SYNTH
            cur_idx = verisimpleV.rob0.rtre_idxs[n];
`ifdef DEBUG
            id      = rob_debug[cur_idx].id;
`endif
            pc      = rob_debug[cur_idx].NPC - 4;
            block   = memory.unified_memory[pc[31:3]];
            inst    = block.word_level[pc[2]];
            reg_idx = verisimpleV.rob0.r_out.entries[n].dst;
            tag     = verisimpleV.retire_exec.tag[n];
            t_old   = verisimpleV.retire_exec.t_old[n];
            data    = verisimpleV.prf0.file[
                verisimpleV.rob0.r_out.entries[n].tag
            ];
            // print the committed instructions to the writeback output file
            if (reg_idx == `ZERO_REG) begin
`ifdef CYCLE_PRINT
                    $fdisplay(wb_fileno, "(%4d) PC %4x:%-8s| ---          | CYCLE=%0d", id, pc, decode_inst(inst), clock_count);
`endif

`ifndef CYCLE_PRINT
                    $fdisplay(wb_fileno, "PC %4x:%-8s| ---", pc, decode_inst(inst));
`endif
            end else begin

`ifdef CYCLE_PRINT
                $fdisplay(wb_fileno, "(%4d) PC %4x:%-8s| r%02d=%-8x | CYCLE=%0d (t_old: %2d -> t: %2d)",
                          id,
                          pc,
                          decode_inst(inst),
                          reg_idx,
                          data,
                          clock_count,
                          t_old,
                          tag
                );
`endif 

`ifndef CYCLE_PRINT
                $fdisplay(wb_fileno, "PC %4x:%-8s| r%02d=%-8x",
                          pc,
                          decode_inst(inst),
                          reg_idx,
                          data);
`endif
            end

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


    localparam CACHE_LINES  = `DCACHE_LINES;
    localparam INDEX_BITS   = $clog2(CACHE_LINES);
    localparam OFFSET_BITS  = 3;
    localparam TAG_WIDTH    = 32 - INDEX_BITS - OFFSET_BITS;
    function automatic ADDR recons_addr(
        input logic [INDEX_BITS-1:0] way,
        input logic [TAG_WIDTH-1:0]  tag
    );
        return {
            tag,
            way,
            3'b000
        };
    endfunction

    // Show contents of Unified Memory in both hex and decimal
    // Also output the final processor status
    task show_final_mem_and_status;
        input EXCEPTION_CODE final_status;
        int showing_data;
        QUERY_CACHE_RES cache_res;
        begin
            MEM_BLOCK blk, cache_blk, mem_blk;
            $fdisplay(out_fileno, "\nFinal memory state and exit status:\n");
            $fdisplay(out_fileno, "@@@ Unified Memory contents hex on left, decimal on right: ");
            $fdisplay(out_fileno, "@@@");
            showing_data = 0;
            for (int k = 0; k <= `MEM_64BIT_LINES - 1; k = k+1) begin
                cache_res = _query_cache(
                    dbg_dcache.hdr,
                    dbg_dcache.memDP,
                    k
                );
                mem_blk     = memory.unified_memory[k];
                blk         = cache_res.vdm ? cache_res.blk : mem_blk;
                if (blk != 0) begin
                    $fdisplay(out_fileno, "@@@ mem[%5d] = %x : %0d", k*8, blk, blk);
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
                NO_ERROR:          $fdisplay(out_fileno, "@@@ System halted. But no error");
                default:           $fdisplay(out_fileno, "@@@ System halted on unknown error code %x", final_status);
            endcase
            $fdisplay(out_fileno, "@@@");
            $fclose(out_fileno);
        end
    endtask // task show_final_mem_and_status


`ifdef DEBUG
    task print_btq;
        verisimpleV.btq0.print_btq();
    endtask

    task print_map_table();
        verisimpleV.map_table0.print_map_table();
    endtask

    task print_prf;
        verisimpleV.prf0.print_prf();
    endtask

    task print_rob;
        verisimpleV.rob0.print_rob();
    endtask

    task print_rs;
        verisimpleV.rs0.print_rs();
    endtask

    task print_retire;
        verisimpleV.retire0.print_retire();
    endtask

    task print_dcache;
        // verisimpleV.dcache0.print_dcache();
    endtask

    task print_execute();
        verisimpleV.ex0.print_execute();
    endtask

    task print_fl();
        verisimpleV.free_list0.print_fl();
    endtask

    task print_fetch;
        verisimpleV.fetch0.print_fetch();
    endtask

    task print_btb;
        verisimpleV.fetch0.btb0.print_btb();
    endtask

    task print_decode;
        verisimpleV.decode0.print_decode();
    endtask

    task print_dispatch;
        verisimpleV.dispatch0.print_dispatch();
    endtask


    task print_custom_data;
        int cycle_no;
        cycle_no = clock_count - 1;
        if (!print_en)
            return;

        $display("  | >> CYCLE: %3d (t: %3d)", clock_count-1, $time);
        print_btb();
        print_fetch();
        print_decode();
        print_rob();
        print_fl();
        print_dispatch();
        print_map_table();
        print_prf();
        print_btq();
        print_rs();
        print_execute();
        print_dcache();
        print_retire();
        $display("  | << CYCLE: %3d (t: %3d)", clock_count-1, $time);

        // $display("---- rob_debug contents ----");
        // foreach (rob_debug[idx]) begin
        //     $display("rob_debug[%2d]: halt=%b, illegal=%b, NPC=0x%08x",
        //             idx,
        //             rob_debug[idx].halt,
        //             rob_debug[idx].illegal,
        //             rob_debug[idx].NPC);
        // end
        // $display("----------------------------");
        // $display(
        //     "## proc2mem: {cmd: %s, addr: %x, data: %x}\n## mem2proc: {txn_tag: %2d, data: %x, data_tag: %2d}",
        //      proc2mem_command,
        //      proc2mem_addr,
        //      proc2mem_data,
        //      mem2proc_transaction_tag,
        //      mem2proc_data,
        //      mem2proc_data_tag
        // );
    endtask
`endif // DEBUG


endmodule // module testbench
