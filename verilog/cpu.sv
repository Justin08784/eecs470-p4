`include "sys_defs.svh"
`include "dcache_block_direct.svh"

module cpu (
    input  clock,
    input  reset,

    output ADDR         [`N-1:0] f2mem_PCs,
    input  MEM_BLOCK    [`N-1:0] mem2f_data,

    input  MEM_TAG      mem2proc_transaction_tag, // Memory tag for current transaction
    input  MEM_BLOCK    mem2proc_data,            // Data coming back from memory
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
    input  MEM_TAG      mem2proc_data_tag,        // Tag for which transaction data is for

    output MEM_COMMAND  proc2mem_command, // Command sent to memory
    output ADDR         proc2mem_addr,    // Address sent to memory
    output MEM_BLOCK    proc2mem_data,    // Data sent to memory
    output MEM_SIZE     proc2mem_size,    // Data size sent to memory

    output DBG_dcache   dbg_dcache,

`ifdef DEBUG
    input  logic        print_en, // high iff current cycle in dbg cycle range
    output DBG_execute  dbg_execute,
    output DBG_fl       dbg_fl,
    output DBG_btq      dbg_btq,
    output DBG_fetch    dbg_fetch,
    output DBG_decode   dbg_decode,
    output DBG_dispatch dbg_dispatch,
    output DBG_lq       dbg_lq,
    output DBG_mt       dbg_mt,
    output DBG_prf      dbg_prf,
    output DBG_rob      dbg_rob,
    output DBG_rs       dbg_rs,
    output DBG_sq       dbg_sq,
    output DBG_retire   dbg_retire,
`endif 

    output COMMIT_PACKET [`N-1:0] committed_insts
);
    /* Global controls*/
    logic flush;


    /* Memory stubs */
    always_comb begin
        proc2mem_command    = MEM_NONE;
        proc2mem_addr       = '0;
        proc2mem_data       = '0;
        proc2mem_size       = DOUBLE;

        dbg_dcache = '0;
    end


    /* >> ==== Fetch ==== >> */
    fetch2decode f_2_decode;
    decode2fetch decode_2_f;
    retire2fetch retire_2_f;

    stage_if_p4 fetch_0(
`ifdef DEBUG
        .dbg    (dbg_fetch),
`endif
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .d_in   (decode_2_f),
        .d_out  (f_2_decode),
        .r_in   (retire_2_f),

        .mem_out_PCs    (f2mem_PCs),
        .mem_in_data    (mem2f_data)
    );


    /* >> ==== Decode ==== >> */
    decode2dispatch de_2_disp;
    dispatch2decode disp_2_de;

    stage_id_p4 decoder0 (
`ifdef DEBUG
        .dbg    (dbg_decode),
`endif
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .f_in   (f_2_decode),
        .f_out  (decode_2_f),
        .d_in   (disp_2_de),
        .d_out  (de_2_disp)
    );


    /* >> ==== Dispatch ==== >> */
    rs2dispatch rs_2_dispatch;
    dispatch2rs dispatch_2_rs;
    rob2dispatch rob_2_dispatch;
    dispatch2rob dispatch_2_rob;
    dispatch2free_list dispatch_2_fl;
    free_list2dispatch fl_2_dispatch;
    dispatch2map_table dispatch_2_map;
    map_table2dispatch map_2_dispatch;
    dispatch2btq dispatch_2_btq;
    btq2dispatch btq_2_dispatch;
    execute2complete_tag ex_2_ctag;
    execute2complete_dat ex_2_cdat;

    dispatch dispatcher(
`ifdef DEBUG
        .dbg        (dbg_dispatch),
`endif

        .clock      (clock),
        .reset      (reset),
        .flush      (flush),

        .decode_in  (de_2_disp),
        .decode_out (disp_2_de),
        .rs_in      (rs_2_dispatch),
        .rs_out     (dispatch_2_rs),
        .rob_in     (rob_2_dispatch),
        .rob_out    (dispatch_2_rob),
        .free_in    (fl_2_dispatch),
        .free_out   (dispatch_2_fl),
        .btq_in     (btq_2_dispatch),
        .btq_out    (dispatch_2_btq),
        .map_in     (map_2_dispatch),
        .map_out    (dispatch_2_map),

        .ctag_in    (ex_2_ctag)
    );


    /* >> ==== Retire ==== >> */
    rob2retire rob_2_retire;
    btq2retire btq_2_retire;
    retire2btq retire_2_btq;

    retire_final    retire_exec;
    ADDR            corrected_PC;

    retire retire0 (
`ifdef DEBUG
        .dbg    (dbg_retire),
`endif
        .clock  (clock),
        .reset  (reset),

        .rob_in (rob_2_retire),
        .btq_in (btq_2_retire),
        .btq_out(retire_2_btq),

        .retire_exec    (retire_exec),

        .flush          (flush),
        .corrected_PC   (corrected_PC)
    );
    assign retire_2_f = '{corrected_PC : corrected_PC};


    /* >> ==== Branch target queue (BTQ) ==== >> */
    execute2btq ex_2_btq;

    btq btq_0(
`ifdef DEBUG
        .dbg    (dbg_btq),
`endif

        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .ex_in  (ex_2_btq),

        .r_in   (retire_2_btq),
        .r_out  (btq_2_retire),
        .d_in   (dispatch_2_btq),
        .d_out  (btq_2_dispatch)
    );


    /* >> ==== Reservation station (RS) ==== >> */
    execute2rs      ex_2_rs; 
    rs2execute      rs_2_ex;
    execute2prf     ex_2_prf;
    prf2execute     prf_2_ex;

    rs rs_0(
`ifdef DEBUG
        .dbg        (dbg_rs),
`endif
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),
 
        .d_in   (dispatch_2_rs),
        .d_out  (rs_2_dispatch),
        .ex_in  (ex_2_rs),
        .ex_out (rs_2_ex),
        .ctag_in(ex_2_ctag)
    );


    /* >> ==== ROB ==== >> */
    rob #(
        .ROB_SZ(`ROB_SZ),
        .N(`N)
    ) rob_0 (
`ifdef DEBUG
        .dbg        (dbg_rob),
`endif
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),

        .r_in       (retire_exec),
        .r_out      (rob_2_retire),
        .d_in       (dispatch_2_rob),
        .d_out      (rob_2_dispatch),

        .cdat_in    (ex_2_cdat)
    );


    /* >> ==== Execute ==== >> */
    stage_ex_p4 ex_0 (
`ifdef DEBUG
        .dbg        (dbg_execute),
        .print_en   (print_en),
`endif
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),

        .rs_in      (rs_2_ex),
        .rs_out     (ex_2_rs),

        .prf_in     (prf_2_ex),
        .prf_out    (ex_2_prf),

        .btq_out    (ex_2_btq),

        .ctag_out   (ex_2_ctag),
        .cdat_out   (ex_2_cdat)
    );


    /* >> ==== Map table ==== >> */
    arch_map2map_table am_2_mt;

    map_table #(
        .N(`N)
    ) map_table_0 (
`ifdef DEBUG
        .dbg    (dbg_mt),
`endif
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .am_in  (am_2_mt),
        .d_in   (dispatch_2_map),
        .d_out  (map_2_dispatch)
    );


    /* >> ==== Architectural map (table) ==== >> */
    arch_map #(
        .N(`N)
    ) arch_map_0 (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .mt_out (am_2_mt),
        .r_in   (retire_exec)
    );


    /* >> ==== Free list ==== >> */
    free_list #(
        .N(`N)
    ) free_list_0 (
`ifdef DEBUG
        .dbg    (dbg_fl),
`endif
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),
        .r_in   (retire_exec),
        .d_in   (dispatch_2_fl),
        .d_out  (fl_2_dispatch)
    );


    /* >> ==== Physical register file (PRF) ==== >> */
`ifdef DEBUG
    logic [`PHYS_REG_SZ_R10K-1:0][$bits(DATA)-1:0] dbg_file;
    assign dbg_prf = '{
        file    : dbg_file,
        cdat_in : ex_2_cdat,
        ex_in   : ex_2_prf,
        ex_out  : prf_2_ex
    };
`endif

    prf #(
        .N(`N),
        .BYPASS_EN(1)
    ) prf_0 (
`ifdef DEBUG
        .dbg_file   (dbg_file),
`endif
        .clock      (clock),
        /* 
        Here each X_BY_FU type is coerced into a flat X array type
        This convenience is why we opt to avoid wrapping these I/Os into
        x2y structs.
        */
        .s_en1s     (ex_2_prf.en1s),
        .s_en2s     (ex_2_prf.en2s),
        .s_t1s      (ex_2_prf.t1s),
        .s_t2s      (ex_2_prf.t2s),
        .s_v1s      (prf_2_ex.v1s),
        .s_v2s      (prf_2_ex.v2s),

        .cdat_in    (ex_2_cdat)

    );


    /* >> ==== Pipeline outputs ==== >> */
    // Output the committed instruction to the testbench for counting
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
