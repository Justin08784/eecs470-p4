`include "sys_defs.svh"
`include "dcache_block_direct.svh"

module cpu (
    input  clock,
    input  reset,

    output fetch2mem f2mem,
    input  mem2fetch mem2f,

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
    output COMMIT_PACKET commit
);
    /* Global controls*/
    logic flush;
    WADDR flush_PC;
    BMASK clmsk;


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
    btq2fetch    btq_2_f;
    fetch2btq    f_2_btq;
    rename2snap_bus rnme_2_snap;

    stage_if_p4 fetch0 (
        .clock,
        .reset,
        .flush,
        .clmsk,
        .flush_PC,

        .d_in   (decode_2_f),
        .d_out  (f_2_decode),
        .btq_in (btq_2_f),
        .btq_out(f_2_btq),

        .snap_in(rnme_2_snap),

        .mem_out(f2mem),
        .mem_in (mem2f)
    );


    /* >> ==== Decode ==== >> */
    decode2dispatch de_2_disp;
    dispatch2decode disp_2_de;

    stage_id_p4 decode0 (
        .clock,
        .reset,
        .flush,

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
    execute2complete_tag ex_2_ctag;
    execute2complete_dat ex_2_cdat;
    rename2bman rnme_2_bman;
    bman2rename bman_2_rnme;
    comm2snap_bus   comm_2_snap;

    dispatch dispatch0 (
        .clock,
        .reset,
        .flush,
        .clmsk,

        .d_in       (de_2_disp),
        .d_out      (disp_2_de),
        .rs_in      (rs_2_dispatch),
        .rs_out     (dispatch_2_rs),
        .rob_in     (rob_2_dispatch),
        .rob_out    (dispatch_2_rob),
        .free_in    (fl_2_dispatch),
        .free_out   (dispatch_2_fl),
        .map_in     (map_2_dispatch),
        .map_out    (dispatch_2_map),
        .bman_in    (bman_2_rnme),
        .bman_out   (rnme_2_bman),
        .rnme_snap_out (rnme_2_snap),
        .comm_snap_out (comm_2_snap),

        .ctag_in    (ex_2_ctag)
    );


    /* >> ==== Branch manager ==== >> */
    branch_manager bman (
        .clock,
        .reset,
        .flush,
        .clmsk,

        .dis_in (rnme_2_bman),
        .dis_out(bman_2_rnme)
    );


    /* >> ==== Retire ==== >> */
    rob2retire rob_2_retire;
    btq2retire btq_2_retire;
    retire2btq retire_2_btq;

    retire_final    retire_exec;

    retire retire0 (
        .clock,
        .reset,

        .rob_in (rob_2_retire),
        .btq_in (btq_2_retire),
        .btq_out(retire_2_btq),

        .retire_exec
    );


    /* >> ==== Branch target queue (BTQ) ==== >> */
    execute2btq ex_2_btq;
    btq2execute btq_2_ex;

    btq btq0(
        .clock,
        .reset,
        .flush,
        .clmsk,
        .snap_in(rnme_2_snap),

        .ex_in  (ex_2_btq),
        .ex_out (btq_2_ex),

        .r_in   (retire_2_btq),
        .r_out  (btq_2_retire),
        .f_in   (f_2_btq),
        .f_out  (btq_2_f)
    );


    /* >> ==== Reservation station (RS) ==== >> */
    execute2rs      ex_2_rs; 
    rs2execute      rs_2_ex;
    execute2prf     ex_2_prf;
    prf2execute     prf_2_ex;

    rs rs0(
        .clock,
        .reset,
        .flush,
        .clmsk,
 
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
    ) rob0 (
        .clock,
        .reset,
        .flush,
        .clmsk,
        .snap_in(comm_2_snap),

        .r_in       (retire_exec),
        .r_out      (rob_2_retire),
        .d_in       (dispatch_2_rob),
        .d_out      (rob_2_dispatch),

        .cdat_in    (ex_2_cdat)
    );


    /* >> ==== Execute ==== >> */
    stage_ex_p4 ex0 (
        .clock,
        .reset,
        .flush,
        .flush_PC,
        .clmsk,

        .rs_in      (rs_2_ex),
        .rs_out     (ex_2_rs),

        .prf_in     (prf_2_ex),
        .prf_out    (ex_2_prf),

        .btq_in     (btq_2_ex),
        .btq_out    (ex_2_btq),

        .ctag_out   (ex_2_ctag),
        .cdat_out   (ex_2_cdat)
    );


    /* >> ==== Map table ==== >> */
    arch_map2map_table am_2_mt;
`ifdef DEBUG
    struct packed {
        logic [`PHYS_REG_SZ_R10K-1:0][$bits(DATA)-1:0] file;
    } dbg_prf;
`endif

    map_table #(
        .N(`N)
    ) map_table0 (
`ifdef DEBUG
        .dbg_prf,
`endif
        .clock,
        .reset,
        .flush,
        .clmsk,
        .snap_in(rnme_2_snap),

        .d_in   (dispatch_2_map),
        .d_out  (map_2_dispatch)
    );


    /* >> ==== Architectural map (table) ==== >> */
    /*
    FIXME: We no longer need the arch_map for CPU functionality. However,
    it may be useful to instantiate this in cpu_test.sv for debugging.
    */
    // arch_map #(
    //     .N(`N)
    // ) arch_map0 (
    //     .clock,
    //     .reset,
    //     .flush,

    //     .mt_out (am_2_mt),
    //     .r_in   (retire_exec)
    // );


    /* >> ==== Free list ==== >> */
    free_list #(
        .N(`N)
    ) free_list0 (
        .clock,
        .reset,
        .flush,
        .clmsk,
        .snap_in(rnme_2_snap),
        .r_in_n (retire_exec), // *_n -> retire_exec is flopped internally
        .d_in   (dispatch_2_fl),
        .d_out  (fl_2_dispatch)
    );


    /* >> ==== Physical register file (PRF) ==== >> */
    prf #(
        .N(`N)
    ) prf0 (
`ifdef DEBUG
        .dbg_file   (dbg_prf.file),
`endif
        .clock,
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
    // Output committed instructions to the testbench for counting
    assign commit = '{
        r_en_cnt: retire_exec.r_en_cnt,
        halt    : retire_exec.halt,
        illegal : retire_exec.illegal
    };

endmodule // pipeline
