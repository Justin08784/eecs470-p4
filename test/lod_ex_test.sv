`timescale 1ns / 1ps
`include "sys_defs.svh"
`include "execute.svh"
`include "dcache.svh"
/*
WARNING: This must be run in DEBUG mode. (it won't compile otherwise)
*/

function automatic string dbg_mem_cmd(input MEM_COMMAND cmd);
    string rv;
    case (cmd)
        MEM_NONE:   rv = "NONE";
        MEM_STORE:  rv = "STOR";
        MEM_LOAD:   rv = "LOAD";
    endcase
    return rv;
endfunction

function automatic string dbg_mem_size(input MEM_SIZE size);
    string rv;
    case (size)
        BYTE:   rv = "BYTE";
        HALF:   rv = "HALF";
        WORD:   rv = "WORD";
        DOUBLE: rv = "DBLE";
    endcase
    return rv;
endfunction

module lod_ex_test;
    DBG_lod_ex dbg;

    logic clock;
    logic reset;
    logic flush;

    logic    [`NUM_FU_LOAD-1:0]  i_rdy;
    logic    [`NUM_FU_LOAD-1:0]  i_vld;
    LOD_REGS [`NUM_FU_LOAD-1:0]  i_regs;

    dcache2ld dcache_in;
    ld2dcache dcache_out;
    
    sq2execute sq_in;
    execute2sq sq_out;
    execute2lq lq_out;
    executeLD2sq ld_sq_out;

    logic    [`NUM_FU_LOAD-1:0]  o_vld;
    CPL_CAND [`NUM_FU_LOAD-1:0]  o_cands;
    logic    [`NUM_FU_LOAD-1:0]  o_rdy;

    // Instantiate the DUT
    lod_ex dut (
        .dbg,

        .clock,
        .reset,
        .flush('0),

        .i_rdy,
        .i_vld,
        .i_regs,

        .dcache_in,
        .dcache_out,

        .sq_in,
        .sq_out,
        .lq_out(),
        .ld_sq_out,

        .o_vld,
        .o_cands,
        .o_rdy
    );

    task set_in(
        input ADDR      addr,
        input MEM_SIZE  sz
    );
    endtask

    task set_ldb(
        input MEM_TAG   tag,
        input MEM_BLOCK v,
        input MEM_SIZE  sz
    );
    endtask

    task clr_inputs();
        {   
            i_vld,
            i_regs,
            dcache_in,
            sq_in,
            o_rdy

        } = '0;
    endtask

    task print_bay();
        $display("Load bay");
        for (int i = 0; i < `LD_BAY_SZ; ++i)
            if (dbg.bay[i].vld)
                $display("  bay[%1d]: vld=%b, addr=%x, mem_size=%s, queried=%b, hit=%b, nbmsk=%b, raw_dat=%x, miss_tag=%2d, sq_idx=%1d",
                    i,
                    dbg.bay[i].vld,
                    dbg.bay[i].addr,
                    dbg_mem_size(dbg.bay[i].mem_size),
                    dbg.bay[i].queried,
                    dbg.bay[i].hit,
                    dbg.bay[i].need_byte_mask,
                    dbg.bay[i].raw_dat,
                    dbg.bay[i].miss_tag,
                    dbg.bay[i].sq_idx
                );
            else
                $display("  bay[%1d]:", i);
    endtask

    task print_ldbuf();
        $display("Load buffer");
        for (int i = 0; i < `LD_BAY_SZ; ++i)
            if (dbg.ldbuf[i].vld)

                $display("  ld_buf[%1d]: vld=%b, got=%b, acc={b:%1d, h:%1d, w:%1d}, mem_size=%s, miss_tag=%2d, dat=%x",
                    i,
                    dbg.ldbuf[i].vld,
                    dbg.ldbuf[i].got,
                    dbg.ldbuf[i].acc.byte_off,
                    dbg.ldbuf[i].acc.half_off,
                    dbg.ldbuf[i].acc.word_off,
                    dbg_mem_size(dbg.ldbuf[i].mem_size),
                    dbg.ldbuf[i].miss_tag,
                    dbg.ldbuf[i].dat
                );
            else
                $display("  ld_buf[%1d]:", i);
    endtask

    task print_cdb_shr();
        $display("CDB SHR");
        for (int i = 0; i < 2; ++i)
            if (dbg.cdb_buf_shr[i].vld)

                $display("  cdb_shr[%1d]: vld=%b, dat=%x",
                    i,
                    dbg.cdb_buf_shr[i].vld,
                    dbg.cdb_buf_shr[i].dat
                );
            else
                $display("  cdb_shr[%1d]:", i);
    endtask

    // Clock generation
    logic enable_prints = 0;
    localparam DCACHE_CLOCK = 50;
    always begin
        #(DCACHE_CLOCK/2);
        clock = ~clock;
    end

    always @(negedge clock) begin
        if (enable_prints) begin
            // $display("i_vld:%b bay_rdy_gnt:%b", dbg.i_vld, dbg.bay_rdy_gnt);
            // $display("bay_gnt_query:%b dispatch_en:%b", dbg.bay_gnt_query, dbg.dispatch_en);
            print_bay();
            print_ldbuf();
            print_cdb_shr();
        end
    end

    initial begin
        $display("Starting dcache testbench...");
        clock = 0;
        reset = 0;
        clr_inputs();

        $display("\n  %16t : Asserting Reset", $realtime);
        reset = 1;
        for (int i = 0; i < 6; ++i)
            @(negedge clock);
        $display("  %16t : Loading Unified Memory", $realtime);
        $display("  %16t : Deasserting Reset", $realtime);
        reset = 0;
        enable_prints = 1;

        // wr('h80, 'hbeeffeed, WORD);
        i_vld = 1;
        i_regs[0] = '0;
        i_regs[0].dat.opb = 4;
        i_regs[0].dat.mem_size = WORD;
        #0;
        @(negedge clock);
        clr_inputs();
        @(negedge clock);
        @(negedge clock);

        $display("Finished dcache testbench.");
        $finish;
    end

endmodule