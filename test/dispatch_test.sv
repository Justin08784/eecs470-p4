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
    map_table2dispatch map_in;
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

        .map_in(map_in),
        .map_out(map_out)
    );

    task set_decode(
        input int d_vld_scnt,
        input logic [1:0] prvw_has_dests
    );
        decode_in.d_vld_scnt = d_vld_scnt;
        decode_in.prvw_has_dests = prvw_has_dests;
    endtask


    task set_decode_dat(
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
        input int rdy,
        input ROB_IDX id0,
        input ROB_IDX id1
    );
        rob_in.rob_rdy_scnt = rdy;
        rob_in.rob_idxs[0] = id0;
        rob_in.rob_idxs[1] = id1;
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

    task set_map(
        int i,
        logic cpl1s,
        logic cpl2s,
        PHYS_REG_IDX t1s,
        PHYS_REG_IDX t2s,
        PHYS_REG_IDX ts
    );
        map_in.ts_old[i] = ts;
        map_in.t1s[i] = t1s;
        map_in.t2s[i] = t2s;
        map_in.cpl1s[i] = cpl1s;
        map_in.cpl2s[i] = cpl2s;
    endtask

    task clear_all();
        decode_in = '0;
        rs_in = '0;
        rob_in = '0;
        free_in = '0;
        lsq_in = '0;
        map_in = '0;
    endtask

    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end


    task chk_dat(
        int i,
        logic cpl1s,
        logic cpl2s,
        PHYS_REG_IDX t1s,
        PHYS_REG_IDX t2s,
        PHYS_REG_IDX ts,
        ROB_IDX idx,
        string msg
    );
    $display("RS[%1d]: %2d", i, rs_out.d_dat[i].t);
    assert (rs_out.d_dat[i].t == ts)
        else exit_on_error (msg);
    assert (rs_out.d_dat[i].t1 == t1s)
        else exit_on_error (msg);
    assert (rs_out.d_dat[i].t2 == t2s)
        else exit_on_error (msg);
    assert (rs_out.d_dat[i].t1_rdy == cpl1s)
        else exit_on_error (msg);
    assert (rs_out.d_dat[i].t2_rdy == cpl2s)
        else exit_on_error (msg);
    assert (rs_out.d_dat[i].rob_idx == idx)
        else exit_on_error (msg);
    endtask


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
        assert (decode_out.dispatch_en_cnt == '0)
            else exit_on_error ("test_reset decode error");
        assert (rs_out.d_en_cnt == 0)
            else exit_on_error ("test_reset rs error");
        assert (rob_out.d_en_cnt == 0)
            else exit_on_error ("test_reset rob error");
        assert (free_out.free_d_en_cnt == 0)
            else exit_on_error ("test_reset free error");
        assert (lsq_out.lsq_d_en_cnt == 0)
            else exit_on_error ("test_reset lsq error");
        assert (map_out.en_cnt == '0)
            else exit_on_error ("test_reset map error");
        assert (rs_out.d_dat == '0)
            else exit_on_error ("test_reset d_dat error");
        @(negedge clock);
        reset = 0;

        @(negedge clock);
        set_rs(2);
        set_rob(2,24,25);
        set_free(2,3,4);
        set_lsq(2);
        set_map(0,1,1,12,13,14);
        set_map(1,0,0,15,16,17);
        reset = 1;

        @(negedge clock);
        assert (decode_out.dispatch_en_cnt == '0)
            else exit_on_error ("test_reset decode error");
        assert (rs_out.d_en_cnt == 0)
            else exit_on_error ("test_reset rs error");
        assert (rob_out.d_en_cnt == 0)
            else exit_on_error ("test_reset rob error");
        assert (free_out.free_d_en_cnt == 0)
            else exit_on_error ("test_reset free error");
        assert (lsq_out.lsq_d_en_cnt == 0)
            else exit_on_error ("test_reset lsq error");
        assert (map_out.en_cnt == '0)
            else exit_on_error ("test_reset map error");
        assert (rs_out.d_dat == '0)
            else exit_on_error ("test_reset d_dat error");
        @(negedge clock);
        reset = 0;        
    endtask

    task test_zero();
        reset = 1;
        @(negedge clock);
        reset = 0;

        clear_all();
        @(negedge clock);
        // $display("\n\nRS VALUE: %2d:", rs_out.d_en_cnt);
        assert (decode_out.dispatch_en_cnt == '0)
            else exit_on_error ("test_zero decode error");
        assert (rs_out.d_en_cnt == 2'b0)
            else exit_on_error ("test_zero rs error");
        assert (rob_out.d_en_cnt == 2'b0)
            else exit_on_error ("test_zero rob error");
        assert (free_out.free_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero free error");
        assert (lsq_out.lsq_d_en_cnt == 2'b0)
            else exit_on_error ("test_zero lsq error");
        assert (map_out.en_cnt == '0)
            else exit_on_error ("test_zero map error");
        assert (rs_out.d_dat == '0)
            else exit_on_error ("test_reset d_dat error");

    endtask

    function print_all();
        $display("decode_in: {d_vld_scnt: %d, has_dests: %b, [(t: %d, t1: %d, t2: %d), (t: %d, t1: %d, t2: %d)]}",
            decode_in.d_vld_scnt,
            decode_in.prvw_has_dests,
            decode_in.d_dat[0].t,
            decode_in.d_dat[0].t1,
            decode_in.d_dat[0].t2,
            decode_in.d_dat[1].t,
            decode_in.d_dat[1].t1,
            decode_in.d_dat[1].t2
        );

        $display("map_in: [(told: %d, t1: %d <%b>, t2: %d <%b>), (told: %d, t1: %d <%b>, t2: %d <%b>)]",
            map_in.ts_old[0],
            map_in.t1s[0],
            map_in.cpl1s[0],
            map_in.t2s[0],
            map_in.cpl2s[0],

            map_in.ts_old[1],
            map_in.t1s[1],
            map_in.cpl1s[1],
            map_in.t2s[1],
            map_in.cpl2s[1]
        );

        $display("rs_in: {rs_rdy_scnt: %d}",
            rs_in.rs_rdy_scnt
        );

        $display("rob_in: {rob_rdy_scnt: %d, rob_idxs: [%d, %d]}",
            rob_in.rob_rdy_scnt,
            rob_in.rob_idxs[0],
            rob_in.rob_idxs[1]
        );

        $display("free_in: {free_rdy_scnt: %d, d_ts: [%d, %d]}",
            free_in.free_rdy_scnt,
            free_in.d_ts[0],
            free_in.d_ts[1]
        );



    endfunction

    task test_two_rdy();
        reset = 1;
        @(negedge clock);
        reset = 0;

        clear_all();
        @(negedge clock);
        set_rs(2);
        set_rob(2,24,25);
        set_free(2,8,16);
        set_lsq(2);
        set_decode(2,2'b11);
        set_decode_dat(0,1,2,3,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_decode_dat(1,4,5,6,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_map(0,1,1,12,13,14);
        set_map(1,0,0,15,17,18);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.dispatch_en_cnt == 2)
            else exit_on_error ("test_two decode error");
        assert (rs_out.d_en_cnt == 2)
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
        assert (map_out.ts[0] == 16)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.ts[1] == 8)
            else exit_on_error ("test_two_rdy map error");

        assert (map_out.src1s[0] == 2)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[0] == 3)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src1s[1] == 5)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[1] == 6)
            else exit_on_error ("test_two_rdy map error");

        chk_dat(0,1,1,12,13,16,24,"test_two d_dat error");
        chk_dat(1,0,0,15,17,8,25,"test_two d_dat error");

        @(negedge clock);
        set_decode(2,2'b11);
        set_decode_dat(0,0,2,3,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_decode(2,2'b10);
        set_map(1,0,0,15,16,0);

        @(negedge clock);
        assert (decode_out.dispatch_en_cnt == 2)
            else exit_on_error ("test_two decode error");
        assert (rs_out.d_en_cnt == 2)
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
        assert (map_out.ts[1] == 8)
            else exit_on_error ("test_two_rdy map error");

        assert (map_out.src1s[0] == 2)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[0] == 3)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src1s[1] == 5)
            else exit_on_error ("test_two_rdy map error");
        assert (map_out.src2s[1] == 6)
            else exit_on_error ("test_two_rdy map error");

        // chk_dat(0,1,1,12,13,14,24,"test_two d_dat error");
        // chk_dat(1,0,0,15,16,0,25,"test_two d_dat error");
    endtask

    task test_one_rdy();
        reset = 1;
        @(negedge clock);
        reset = 0;

        clear_all();
        @(negedge clock);
        set_rs(1);
        set_rob(2,24,25);
        set_free(2,8,16);
        set_lsq(2);
        set_decode(2,2'b11);
        set_decode_dat(0,1,2,3,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_decode_dat(1,4,5,6,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_map(0,1,1,12,13,14);
        set_map(1,0,0,15,16,17);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.dispatch_en_cnt == 1)
            else exit_on_error ("test_one decode error");
        assert (rs_out.d_en_cnt == 1)
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
            else exit_on_error ("test_one_rdy map error");
        assert (map_out.ts[0] == 8)
            else exit_on_error ("test_one_rdy map error");
        assert (map_out.dsts[1] == 0)
            else exit_on_error ("test_one_rdy map error");
        assert (map_out.ts[1] == 0)
            else exit_on_error ("test_one_rdy map error");

        assert (map_out.src1s[0] == 2)
            else exit_on_error ("test_one_rdy map error");
        assert (map_out.src2s[0] == 3)
            else exit_on_error ("test_one_rdy map error");
        assert (map_out.src1s[1] == 0)
            else exit_on_error ("test_one_rdy map error");
        assert (map_out.src2s[1] == 0)
            else exit_on_error ("test_one_rdy map error");

        chk_dat(0,1,1,12,13,14,24,"test_one_rdy d_dat error");
        chk_dat(1,0,0,0,0,0,0,"test_one_rdy d_dat error");

        @(negedge clock);
        set_rs(2);
        set_rob(1,24,25);
        set_free(2,3,4);
        set_lsq(2);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.dispatch_en_cnt == 1)
            else exit_on_error ("test_one decode error");
        assert (rs_out.d_en_cnt == 1)
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
        set_rob(2,24,25);
        set_free(1,3,4);
        set_lsq(2);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.dispatch_en_cnt == 1)
            else exit_on_error ("test_one decode error");
        assert (rs_out.d_en_cnt == 1)
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
        set_rob(2,24,25);
        set_free(2,3,4);
        set_lsq(1);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.dispatch_en_cnt == 1)
            else exit_on_error ("test_one decode error");
        assert (rs_out.d_en_cnt == 1)
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
        set_rob(3,24,25);
        set_free(3,8,16);
        set_lsq(3);
        set_decode(2,2'b11);
        set_decode_dat(0,1,2,3,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);
        set_decode_dat(1,4,5,6,OPA_IS_RS1,OPB_IS_RS2,0,0,0,0);

        @(negedge clock);
        // $display("\n\nFREE VALUE: %2d:", free_in.free_rdy_scnt);
        assert (decode_out.dispatch_en_cnt == 2)
            else exit_on_error ("test_too_many decode error");
        assert (rs_out.d_en_cnt == 2)
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
        // test_one_rdy();
        // test_too_many();

        if (failed)
            $display("@@@ Failed\n");
        else
            $display("\n\033[32m@@@ Passed\033[0m\n");

        $finish;
    end

endmodule