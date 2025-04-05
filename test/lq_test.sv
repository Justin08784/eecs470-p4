`include "sys_defs.svh"


module lq_testbench;

    logic clock;
    logic reset;
    logic flush;

    dispatch2lq dis_2_lq;
    rob2lq rob_2_lq;
    execute2lq exec_2_lq;

    lq2dispatch lq_2_dis;
    lq2rob lq_2_rob;

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

    lq lq_dut(
        .clock(clock),
        .reset(reset),
        .flush(flush),

        .dis_2_lq(dis_2_lq),
        .rob_2_lq(rob_2_lq),
        .exec_2_lq(exec_2_lq),

        .lq_2_dis(lq_2_dis),
        .lq_2_rob(lq_2_rob)
    );


    initial begin
        clock = 0;
        reset = 0;
        flush = 0;


        dis_2_lq = '0;
        rob_2_lq = '0;
        // exec_2_lq = '0;

        @(negedge clock);
        reset = 1;
        @(negedge clock);
        reset = 0;
        @(negedge clock);
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 0;
        dis_2_lq.rob_idx[1] = 1;
        @(negedge clock);
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 2;
        dis_2_lq.rob_idx[1] = 3;
        assert (lq_2_rob.ret_rdy == 0) 
        else exit_on_error("ret_rdy not 0");
        @(negedge clock);
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 4;
        dis_2_lq.rob_idx[1] = 5;
        
        exec_2_lq.ld_ex_en[0] = '1;
        exec_2_lq.ld_lq_idx[0] = 0;
        exec_2_lq.ld_addr[0] = 4;
        exec_2_lq.ld_mem_size[0] = HALF;
        exec_2_lq.ld_ex_en[1] = '1;
        exec_2_lq.ld_lq_idx[1] = 1;
        exec_2_lq.ld_addr[1] = 76;
        exec_2_lq.ld_mem_size[1] = WORD;

        @(negedge clock);
        assert (lq_2_rob.ret_rdy == 2) 
        else exit_on_error("ret_rdy not 2");
        @(negedge clock);
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 6;
        dis_2_lq.rob_idx[1] = 7;
        @(negedge clock);
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 8;
        dis_2_lq.rob_idx[1] = 9;
        @(negedge clock);
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 10;
        dis_2_lq.rob_idx[1] = 11;
        @(negedge clock);
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 12;
        dis_2_lq.rob_idx[1] = 13;
        @(negedge clock);
        rob_2_lq.r_en = 2;
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 14;
        dis_2_lq.rob_idx[1] = 15;
        exec_2_lq.ld_ex_en[0] = '1;
        exec_2_lq.ld_lq_idx[0] = 6;
        exec_2_lq.ld_addr[0] = 24;
        exec_2_lq.ld_mem_size[0] = WORD;
        exec_2_lq.ld_ex_en[1] = '1;
        exec_2_lq.ld_lq_idx[1] = 9;
        exec_2_lq.ld_addr[1] = 33;
        exec_2_lq.ld_mem_size[1] = BYTE;
        @(negedge clock);
        exec_2_lq = '0;
        rob_2_lq.r_en = 1;
        dis_2_lq.lq_d_en_cnt = 2;
        dis_2_lq.rob_idx[0] = 16;
        dis_2_lq.rob_idx[1] = 17;
        @(negedge clock);
        rob_2_lq = '0;
        dis_2_lq.lq_d_en_cnt = 1;
        dis_2_lq.rob_idx[0] = 18;
        dis_2_lq.rob_idx[1] = 19;
        @(negedge clock);
        dis_2_lq = '0;
        @(posedge clock);
        $display("Ret Rdy: %0d", lq_2_rob.ret_rdy);
        assert (lq_2_rob.ret_rdy == 0) 
        else exit_on_error("ret_rdy not 0");
        @(negedge clock);
        @(negedge clock);


        $display("\n\033[32m@@@ Passed\033[0m\n");
        $finish;
    end
endmodule