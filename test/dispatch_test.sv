`include "sys_defs.svh"


module dispatch_testbench;
    localparam N=`N;

    // constants
    // signals
    logic clock;
    logic reset;
    logic flush;
    logic failed;

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
        REG_IDX       [N-1:0] src1s;
        REG_IDX       [N-1:0] src2s;
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


    task set_decode(
        input int i,
        input int rd,
        input int rs1,
        input int rs2,
        input int opa_select,
        input int opb_select,
        input int wr_mem,
        input int cond_branch,
        input int uncond_branch,
        input int halt
    );
        static ADDR nex_id = 0;
        // Set up a valid dispatch line

        decode_in.d_dat[i]        = '0;
        decode_in.d_dat[i].inst.r.rd  = rd;
        decode_in.d_dat[i].inst.r.rs1 = rs1;
        decode_in.d_dat[i].inst.r.rs2 = rs2;
        decode_in.d_dat[i].opa_select = opa_select;
        decode_in.d_dat[i].opb_select = opb_select;
        decode_in.d_dat[i].wr_mem = wr_mem;
        decode_in.d_dat[i].cond_branch = cond_branch;
        decode_in.d_dat[i].uncond_branch = uncond_branch;
        decode_in.d_dat[i].halt = halt;
        // we use id to uniquely identify each instruction
        decode_in.d_dat[i].id     = nex_id++;
    endtask

    task clr_decode(
        input int i
    );
        decode_in.d_dat[i] = '0;
    endtask


    task set_rs(
        input int rdy
    );
        rs_in.rs_rdy_scnt = rdy;
    endtask

    task clr_rs(

    );
        rs_in = '0;
    endtask


    task set_rob(
        input int rdy
    );
        rob_in.rob_rdy_scnt = rdy;
    endtask

    task clr_rob(

    );
        rob_in = '0;
    endtask

    task set_free(
        input rdy,
        input t0,
        input t1
    );
        free_in.free_rdy_scnt = rdy;
        free_in.d_ts[0] = t0;
        free_in.d_ts[1] = t1;
    endtask

    task clr_free(

    );
        free_in = '0;
    endtask

    task set_lsq(
        input rdy
    );
        lsq_in.lsq_rdy_scnt = rdy;
    endtask

    task clr_lsq(

    );
        lsq_in = '0;
    endtask

    task clear_all();
        decode_in = '0;
        rs_in = '0;
        rob_in = '0;
        free_in = '0;
        lsq_in = '0;
    endtask

    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end


    task exit_on_error(input string msg);
        begin
            // print_failure();
            $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
            $display("\033[31mError: %0s\033[0m\n\n", msg);
            // foreach(id2idx[id]) $display("id2[%0d]: %0d", id, id2idx[id]);
            // foreach(id2idx_n[id]) $display("id2_n[%0d]: %0d", id, id2idx_n[id]);
            // $display("entries:");
            // print_entries(entries);
            // $display("entries_cur:");
            // print_entries(entries_cur);

            $finish;
        end
    endtask


    //TESTS

    task test_reset();
        reset = 1;
        @(negedge clock);
        assert (rs_out.rs_d_en_cnt == 0)
            else exit_on_error ("test_reset rs error");
        assert (rob_out.rob_d_en_cnt == 0)
            else exit_on_error ("test_reset rob error");
        assert (free_out.free_d_en_cnt == 0)
            else exit_on_error ("test_reset free error");
        assert (lsq_out.lsq_d_en_cnt == 0)
            else exit_on_error ("test_reset lsq error");
        @(negedge clock);
        reset = 0;
    endtask

    task test_zero();
        reset = 1;
        @(negedge clock);
        reset = 0;

        clear_all();
        @(negedge clock);
        // $display("\n\nRS VALUE: %2d:", rs_out.rs_d_en_cnt);
        assert (rs_out.rs_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero rs error");
        assert (rob_out.rob_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero rob error");
        assert (free_out.free_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero free error");
        assert (lsq_out.lsq_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero lsq error");

    endtask


    initial begin
        clock = 0;
        failed = 0;


        clear_all();

        test_reset();
        test_zero();

        if (failed)
            $display("@@@ Failed\n");
        else
            $display("@@@ Passed\n");

        $finish;
    end

endmodule