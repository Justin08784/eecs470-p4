`include "sys_defs.svh"


module dispatch_testbench;
    localparam N=`N;

    // constants
    // signals
    logic clock;
    logic reset;
    logic flush;

    // DECODE
    struct packed {
        ID_RESULT   [N-1:0]     d_dat;
    } decode_in;

    struct packed {
        logic       [$clog2(N):0] decode_d_en_cnt;
    } decode_out;
    

    // RS
    struct packed {
        logic       [$clog2(N):0] rs_rdy_scnt;
            // - From: RS
    } rs_in;

    struct packed {
        logic       [$clog2(N):0] rs_d_en_cnt;
            // - To: RS
            // - Number of enabled dispatch lines? (replacement for d_vld)
            // - Question: permit
            // 1) only N dispatches, OR
            // 2) a different limit number of dispatches DIS_MAX: N ≤ DIS_MAX ≤ RS_SZ
            // (DIS_MAX will be a new sys_defs.svh constant) ?
        // ID_RESULT   [N-1:0] d_dat, //shouldn't have dispatch feed to RS,
            // - To: RS               //should come directly from dispatch
    } rs_out;
    
    
    // ROB
    struct packed {
        logic    [$clog2(N):0]    rob_rdy_scnt;
            // From: ROB
            // saturating counter for number of free rob entries
    } rob_in;

    struct packed {
        logic   [$clog2(N):0]            rob_d_en_cnt;
            // To: ROB
            // - Number of enabled dispatch lines?
        // ROB_ENTRY   [N-1:0]      d_dat, //shouldn't have dispatch feed to ROB,
            // To: ROB                     //should come directly from dispatch
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
    } rob_out;
    

    // Free list
    struct packed {
        logic    [$clog2(N):0]    free_rdy_scnt;
        // From: Free list
        // - sat. count of number of free pregs in free list;
        //   count reflects any pregs returned in retire! (i.e. AFTER retires)
        PHYS_REG_IDX [N-1:0]     d_ts;
        // From: Free list
        // - newly allocated pregs
        // THIS WILL BE 1 CLOCK CYCLE BEHIND. THIS IS DESIRED SO THAT
        // TAGS ARE APPLIED AT THE CORRECT TIMES (paired with map table output)
        // (means that tags will be applied when the dispatched insts actually get
        // to RS/ROB)
    } free_in;

    struct packed {
        logic     [$clog2(N):0]  free_d_en_cnt;
            // To: Free list
            // - number of enabled dispatch lines WHO NEED A DEST PREG 
            //   (e.g. no stores)
            //   (i.e. may only be a strict subset of dispatching insns!)
    } free_out;


    // LSQ
    struct packed {
        logic    [$clog2(N):0]    lsq_rdy_scnt;
    } lsq_in;

    struct packed {
        logic     [$clog2(N):0]  lsq_d_en_cnt;
            // To: LSQ
            // - number of enabled dispatch lines WHO NEED A LD/ST 
            //   (i.e. may only be a strict subset of dispatching insns!)
    } lsq_out;
    
    
    // Map table
    struct packed {
        logic         [$clog2(N):0] en_cnt;
            // - Number of enabled dispatch lines?
            // - NOTE: For in-order stuff with serial deps (like dispatch), use c(ou)nts;
            // otherwise use en(able) buses.
        // REG_IDX       [N-1:0] src1s,
        // output REG_IDX       [N-1:0] src2s,
        REG_IDX       [N-1:0] dsts;
        PHYS_REG_IDX  [N-1:0] ts;
            // To: Map table
            // - IMPORTANT: Set from lowest indices in program-order. NO GAPS!!!
        // THIS WILL BE 1 CLOCK CYCLE BEHIND. THIS IS DESIRED SO THAT
        // TAGS ARE APPLIED AT THE CORRECT TIMES (paired with free list tag output)
        // (means that tags will be applied when the dispatched insts actually get
        // to RS/ROB)
    } map_out;


    dispatch d_dut(
        .clock(clock),
        .reset(reset),
        .flush(1'b0),

        .decode_in(decode_in),
        .decode_out(decode_out),

        .rs_in(rs_in),
        .rs_out(rs_out),

        .rob_in(rob_in),
        .rob_out(rob_out),

        .free_in(free_in),
        .free_out(free_out),

        .lsq_in(lsq_in),
        .lsq_out(lsq_out),

        .map_out(map_out)
    );

endmodule