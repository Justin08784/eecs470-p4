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
    decode2dispatch decode_in;

    dispatch2decode decode_out;
    

    // RS
    rs2dispatch rs_in;

    dispatch2rs rs_out;
    
    
    // ROB
    rob2dispatch rob_in;

    dispatch2rob rob_out;
    

    // Free list
    free_list2dispatch free_in;

    dispatch2free_list free_out;


    // LSQ
    lsq2dispatch lsq_in;

    dispatch2lsq lsq_out;
    
    
    // Map table
    dispatch2map_table map_out;


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
        input int rdy,
        input REG_IDX t0,
        input REG_IDX t1
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
        input int rdy
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
        assert (decode_out.decode_d_en_cnt == '0)
            else exit_on_error ("test_reset decode error");
        assert (rs_out.rs_d_en_cnt == 0)
            else exit_on_error ("test_reset rs error");
        assert (rob_out.d_en_cnt == 0)
            else exit_on_error ("test_reset rob error");
        assert (free_out.free_d_en_cnt == 0)
            else exit_on_error ("test_reset free error");
        assert (lsq_out.lsq_d_en_cnt == 0)
            else exit_on_error ("test_reset lsq error");
        assert (map_out.en_cnt == '0)
            else exit_on_error ("test_reset map error");
        @(negedge clock);
        reset = 0;

        @(negedge clock);
        set_rs(2);
        set_rob(2);
        set_free(2,3,4);
        set_lsq(2);
        reset = 1;

        @(negedge clock);
        assert (decode_out.decode_d_en_cnt == '0)
            else exit_on_error ("test_reset decode error");
        assert (rs_out.rs_d_en_cnt == 0)
            else exit_on_error ("test_reset rs error");
        assert (rob_out.d_en_cnt == 0)
            else exit_on_error ("test_reset rob error");
        assert (free_out.free_d_en_cnt == 0)
            else exit_on_error ("test_reset free error");
        assert (lsq_out.lsq_d_en_cnt == 0)
            else exit_on_error ("test_reset lsq error");
        assert (map_out.en_cnt == '0)
            else exit_on_error ("test_reset map error");
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
        assert (decode_out.decode_d_en_cnt == '0)
            else exit_on_error ("test_zero decode error");
        assert (rs_out.rs_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero rs error");
        assert (rob_out.d_en_cnt == 2'b0)
            else exit_on_error ("test_zero rob error");
        assert (free_out.free_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero free error");
        assert (lsq_out.lsq_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero lsq error");
        assert (map_out.en_cnt == '0)
            else exit_on_error ("test_zero map error");

    endtask

    task test_two_rdy();
        reset = 1;
        @(negedge clock);
        reset = 0;

        clear_all();
        @(negedge clock);
        set_rs(2);
        set_rob(2);
        set_free(2,8,16);
        set_lsq(2);
        set_decode(0,1,2,3,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_decode(1,4,5,6,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.decode_d_en_cnt == 2'b11)
            else exit_on_error ("test_two decode error");
        assert (rs_out.rs_d_en_cnt == 2)
            else exit_on_error ("test_two_rdy rs error");
        assert (rob_out.d_en_cnt == 2)
            else exit_on_error ("test_two_rdy rob error");
        assert (free_out.free_d_en_cnt == 2)
            else exit_on_error ("test_two_rdy free error");
        assert (lsq_out.lsq_d_en_cnt == 2)
            else exit_on_error ("test_two_rdy lsq error");

        assert (map_out.en_cnt == 2)
            else exit_on_error ("test_two_rdy map error");

        assert (map_out.dsts[0] == 1)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.dsts[1] == 4)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.ts[0] == 8)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.ts[1] == 16)
            else exit_on_error ("test_two_rdy map error");

        assert (map_out.src1s[0] == 2)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[0] == 3)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src1s[1] == 5)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[1] == 6)
            else exit_on_error ("test_two_rdy map error");

        @(negedge clock);
        set_decode(0,0,2,3,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);

        @(negedge clock);
        assert (decode_out.decode_d_en_cnt == 2'b11)
            else exit_on_error ("test_two decode error");
        assert (rs_out.rs_d_en_cnt == 2)
            else exit_on_error ("test_two_rdy rs error");
        assert (rob_out.d_en_cnt == 2)
            else exit_on_error ("test_two_rdy rob error");
        assert (free_out.free_d_en_cnt == 1)
            else exit_on_error ("test_two_rdy free error");
        assert (lsq_out.lsq_d_en_cnt == 2)
            else exit_on_error ("test_two_rdy lsq error");

        assert (map_out.en_cnt == 2)
            else exit_on_error ("test_two_rdy map error");

        assert (map_out.dsts[0] == 0)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.dsts[1] == 4)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.ts[0] == 0)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.ts[1] == 16)
            else exit_on_error ("test_two_rdy map error");

        assert (map_out.src1s[0] == 2)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[0] == 3)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src1s[1] == 5)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[1] == 6)
            else exit_on_error ("test_two_rdy map error");
    endtask

    task test_one_rdy();
        reset = 1;
        @(negedge clock);
        reset = 0;

        clear_all();
        @(negedge clock);
        set_rs(1);
        set_rob(2);
        set_free(2,8,16);
        set_lsq(2);
        set_decode(0,1,2,3,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_decode(1,4,5,6,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.decode_d_en_cnt == 2'b01)
            else exit_on_error ("test_one decode error");
        assert (rs_out.rs_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy rs error");
        assert (rob_out.d_en_cnt == 1)
            else exit_on_error ("test_one_rdy rob error");
        assert (free_out.free_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy free error");
        assert (lsq_out.lsq_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy lsq error");

        assert (map_out.en_cnt == 1)
            else exit_on_error ("test_one_rdy map error");

        assert (map_out.dsts[0] == 1)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.ts[0] == 8)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.dsts[1] == 0)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.ts[1] == 0)
            else exit_on_error ("test_two_rdy map error");

        assert (map_out.src1s[0] == 2)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[0] == 3)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src1s[1] == 0)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[1] == 0)
            else exit_on_error ("test_two_rdy map error");

        @(negedge clock);
        set_rs(2);
        set_rob(1);
        set_free(2,3,4);
        set_lsq(2);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.decode_d_en_cnt == 2'b01)
            else exit_on_error ("test_one decode error");
        assert (rs_out.rs_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy rs error");
        assert (rob_out.d_en_cnt == 1)
            else exit_on_error ("test_one_rdy rob error");
        assert (free_out.free_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy free error");
        assert (lsq_out.lsq_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy lsq error");
        assert (map_out.en_cnt == 1)
            else exit_on_error ("test_one_rdy map error");

        @(negedge clock);
        set_rs(2);
        set_rob(2);
        set_free(1,3,4);
        set_lsq(2);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.decode_d_en_cnt == 2'b01)
            else exit_on_error ("test_one decode error");
        assert (rs_out.rs_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy rs error");
        assert (rob_out.d_en_cnt == 1)
            else exit_on_error ("test_one_rdy rob error");
        assert (free_out.free_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy free error");
        assert (lsq_out.lsq_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy lsq error");
        assert (map_out.en_cnt == 1)
            else exit_on_error ("test_one_rdy map error");

        @(negedge clock);
        set_rs(2);
        set_rob(2);
        set_free(2,3,4);
        set_lsq(1);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.decode_d_en_cnt == 2'b01)
            else exit_on_error ("test_one decode error");
        assert (rs_out.rs_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy rs error");
        assert (rob_out.d_en_cnt == 1)
            else exit_on_error ("test_one_rdy rob error");
        assert (free_out.free_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy free error");
        assert (lsq_out.lsq_d_en_cnt == 1)
            else exit_on_error ("test_one_rdy lsq error");
        assert (map_out.en_cnt == 1)
            else exit_on_error ("test_one_rdy map error");
    endtask

    task test_too_many();
    reset = 1;
        @(negedge clock);
        reset = 0;

        clear_all();
        @(negedge clock);
        set_rs(3);
        set_rob(3);
        set_free(3,8,16);
        set_lsq(3);
        set_decode(0,1,2,3,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_decode(1,4,5,6,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.decode_d_en_cnt == 2'b11)
            else exit_on_error ("test_too_many decode error");
        assert (rs_out.rs_d_en_cnt == 2)
            else exit_on_error ("test_too_many rs error");
        assert (rob_out.d_en_cnt == 2)
            else exit_on_error ("test_too_many rob error");
        assert (free_out.free_d_en_cnt == 2)
            else exit_on_error ("test_too_many free error");
        assert (lsq_out.lsq_d_en_cnt == 2)
            else exit_on_error ("test_too_many lsq error");

        assert (map_out.en_cnt == 2)
            else exit_on_error ("test_too_many map error");

        assert (map_out.dsts[0] == 1)
            else exit_on_error ("test_too_many map error");
        assert (map_out.dsts[1] == 4)
            else exit_on_error ("test_too_many map error");
        assert (map_out.ts[0] == 8)
            else exit_on_error ("test_too_many map error");
        assert (map_out.ts[1] == 16)
            else exit_on_error ("test_too_many map error");

        assert (map_out.src1s[0] == 2)
            else exit_on_error ("test_too_many map error");
        assert (map_out.src2s[0] == 3)
            else exit_on_error ("test_too_many map error");
        assert (map_out.src1s[1] == 5)
            else exit_on_error ("test_too_many map error");
        assert (map_out.src2s[1] == 6)
            else exit_on_error ("test_too_many map error");
    endtask


    initial begin
        clock = 0;
        failed = 0;
        reset = 0;
        flush = 0;


        clear_all();

        test_reset();
        test_zero();
        test_two_rdy();
        test_one_rdy();
        test_too_many();

        if (failed)
            $display("@@@ Failed\n");
        else
            $display("@@@ Passed\n");

        $finish;
    end

endmodule