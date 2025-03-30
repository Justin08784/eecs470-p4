`include "sys_defs.svh"


module lsq_testbench;

    logic clock;
    logic reset;
    logic flush;

    dispatch2lsq dis_2_lsq;
    execute2lsq exec_2_lsq;
    rob2lsq rob_2_lsq;

    lsq2dispatch lsq_2_dis;
    lsq2execute lsq_2_exec;
    lsq2rs lsq_2_rs;

    lsq2stRET lsq_2_ret;

    stRET2lsq ret_2_lsq;

    stRET2mem ret_2_mem;
    MEM_TAG mem2proc_transaction_tag;

    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end

    task exit_on_error(input string msg);
        begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
            $display("\033[31mError: %0s\033[0m\n\n", msg);

            $finish;
        end
    endtask

    lsq lsq_dut(
        .clock(clock),
        .reset(reset),
        .flush(flush),

        .dis_2_lsq(dis_2_lsq),
        .exec_2_lsq(exec_2_lsq),
        .rob_2_lsq(rob_2_lsq),
        // .ret_2_lsq(ret_2_lsq),

        .lsq_2_dis(lsq_2_dis),
        .lsq_2_exec(lsq_2_exec),
        .lsq_2_rs(lsq_2_rs),
        // .lsq_2_ret(lsq_2_ret),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),
        .ret_2_mem(ret_2_mem)
    );


    initial begin
        clock = 0;
        reset = 0;
        flush = 0;

        dis_2_lsq = '0;
        exec_2_lsq = '0;
        rob_2_lsq = '0;

        @(negedge clock);
        reset = 1;
        @(negedge clock);
        reset = 0;
        @(negedge clock);
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 0;
        dis_2_lsq.rob_idx[1] = 1;
        @(negedge clock);
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 2;
        dis_2_lsq.rob_idx[1] = 3;
        @(negedge clock);
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 4;
        dis_2_lsq.rob_idx[1] = 5;
        @(negedge clock);
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 6;
        dis_2_lsq.rob_idx[1] = 7;
        @(negedge clock);
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 8;
        dis_2_lsq.rob_idx[1] = 9;
        @(negedge clock);
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 10;
        dis_2_lsq.rob_idx[1] = 11;
        @(negedge clock);
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 12;
        dis_2_lsq.rob_idx[1] = 13;
        @(negedge clock);
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 14;
        dis_2_lsq.rob_idx[1] = 15;
        @(negedge clock);
        dis_2_lsq = '0;
        @(negedge clock);
        exec_2_lsq.sq_idx[0] = 0;
        exec_2_lsq.ex_en[0] = '1;
        exec_2_lsq.addr[0] = 24;
        exec_2_lsq.data[0] = 48;
        exec_2_lsq.sq_idx[1] = 1;
        exec_2_lsq.ex_en[1] = '1;
        exec_2_lsq.addr[1] = 72;
        exec_2_lsq.data[1] = 96;
        assert (lsq_2_dis.sq_rdy_scnt == 0) 
        else   exit_on_error ("Free count not zero");
        @(negedge clock);
        exec_2_lsq = '0;
        rob_2_lsq.r_en = 2;
        assert (lsq_2_rs.en == 4'b0011) 
        else   exit_on_error ("CDB en not correct");
        assert (lsq_2_rs.sq_idx_cdb[0] == 0) 
        else   exit_on_error ("CDB [0] not correct");
        assert (lsq_2_rs.sq_idx_cdb[1] == 1) 
        else   exit_on_error ("CDB [1] not correct");
        @(negedge clock);
        exec_2_lsq = '0;
        rob_2_lsq = '0;
        assert (lsq_2_dis.sq_rdy_scnt == 2) 
        else   exit_on_error ("Free count not two");
        @(negedge clock);
        rob_2_lsq.r_en = 1;
        dis_2_lsq.lsq_d_en_cnt = 2;
        dis_2_lsq.rob_idx[0] = 16;
        dis_2_lsq.rob_idx[1] = 17;
        @(negedge clock);
        rob_2_lsq = '0;
        dis_2_lsq = '0;
        assert (lsq_2_dis.sq_rdy_scnt == 1) 
        else   exit_on_error ("Free count not one");
        @(negedge clock);
        exec_2_lsq.sq_idx[1] = 3;
        exec_2_lsq.ex_en[1] = '1;
        exec_2_lsq.addr[1] = 108;
        exec_2_lsq.data[1] = 120;
        @(negedge clock);
        exec_2_lsq = '0;
        @(negedge clock);
        exec_2_lsq.forward_req_en[0] = 1;
        exec_2_lsq.forward_addr[0] = 24;
        exec_2_lsq.sq_idx[0] = 0;
        exec_2_lsq.forward_req_en[1] = 1;
        exec_2_lsq.forward_addr[1] = 108;
        exec_2_lsq.sq_idx[1] = 3;
        @(posedge clock);
        // $display(lsq_2_exec.forward_en[1]);
        // $display(lsq_2_exec.forward_data[1]);
        assert (lsq_2_exec.forward_en[0] == '1)
        else exit_on_error ("Forward 0 en failed");
        assert (lsq_2_exec.forward_data[0] == 48)
        else exit_on_error ("Forward 0 data failed");
        assert (lsq_2_exec.forward_en[1] == '1)
        else exit_on_error ("Forward 1 en failed");
        assert (lsq_2_exec.forward_data[1] == 120)
        else exit_on_error ("Forward 1 data failed");
        @(negedge clock);
        exec_2_lsq = '0;
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);


        $display("\n\033[32m@@@ Passed\033[0m\n");
        $finish;
    end
endmodule