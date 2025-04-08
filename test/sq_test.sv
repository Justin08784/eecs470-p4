`include "sys_defs.svh"


module sq_testbench;

    logic clock;
    logic reset;
    logic flush;

    dispatch2sq dis_2_sq;
    execute2sq exec_2_sq;
    retire2sq retire_2_sq;

    sq2dispatch sq_2_dis;
    sq2execute sq_2_exec;
    // sq2rs sq_2_rs;

    // sq2stRET sq_2_ret;
    // stRET2sq ret_2_sq;

    stRET2mem ret_2_mem;
    MEM_TAG mem2proc_transaction_tag;
    sq2retire sq_2_retire;

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

    sq sq_dut(
        .clock(clock),
        .reset(reset),
        .flush(flush),

        .dis_2_sq(dis_2_sq),
        .exec_2_sq(exec_2_sq),
        .retire_2_sq(retire_2_sq),
        .mem2proc_transaction_tag(mem2proc_transaction_tag),

        .sq_2_dis(sq_2_dis),
        .sq_2_exec(sq_2_exec),
        // .sq_2_rs(sq_2_rs),
        .ret_2_mem(ret_2_mem),
        .sq_2_retire(sq_2_retire)
    );



    initial begin
        clock = 0;
        reset = 0;
        flush = 0;

        dis_2_sq = '0;
        exec_2_sq = '0;
        retire_2_sq = '0;
        mem2proc_transaction_tag = '0;

        @(negedge clock);
        reset = 1;
        @(negedge clock);
        reset = 0;
        @(negedge clock);
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 0;
        dis_2_sq.rob_idx[1] = 1;
        @(negedge clock);
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 2;
        dis_2_sq.rob_idx[1] = 3;
        @(negedge clock);
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 4;
        dis_2_sq.rob_idx[1] = 5;
        @(negedge clock);
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 6;
        dis_2_sq.rob_idx[1] = 7;
        @(negedge clock);
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 8;
        dis_2_sq.rob_idx[1] = 9;
        @(negedge clock);
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 10;
        dis_2_sq.rob_idx[1] = 11;
        @(negedge clock);
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 12;
        dis_2_sq.rob_idx[1] = 13;
        @(negedge clock);
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 14;
        dis_2_sq.rob_idx[1] = 15;
        @(negedge clock);
        dis_2_sq = '0;
        @(negedge clock);
        exec_2_sq.st_sq_idx[0] = 0;
        exec_2_sq.st_ex_en[0] = '1;
        exec_2_sq.st_addr[0] = 25;
        exec_2_sq.st_data[0] = 48;
        exec_2_sq.st_mem_size[0] = BYTE;
        exec_2_sq.st_sq_idx[1] = 1;
        exec_2_sq.st_ex_en[1] = '1;
        exec_2_sq.st_addr[1] = 74;
        exec_2_sq.st_data[1] = 96;
        exec_2_sq.st_mem_size[1] = BYTE;
        assert (sq_2_dis.sq_rdy_scnt == 0) 
        else   exit_on_error ("Free count not zero");
        @(negedge clock);
        exec_2_sq = '0;
        retire_2_sq.r_en = 2;
        // assert (sq_2_rs.en == 4'b0011) 
        // else   exit_on_error ("CDB en not correct");
        // assert (sq_2_rs.sq_idx_cdb[0] == 0) 
        // else   exit_on_error ("CDB [0] not correct");
        // assert (sq_2_rs.sq_idx_cdb[1] == 1) 
        // else   exit_on_error ("CDB [1] not correct");
        @(negedge clock);
        exec_2_sq = '0;
        retire_2_sq = '0;
        assert (sq_2_dis.sq_rdy_scnt == 2) 
        else   exit_on_error ("Free count not two");
        @(negedge clock);
        retire_2_sq.r_en = 1;
        dis_2_sq.sq_d_en_cnt = 2;
        dis_2_sq.rob_idx[0] = 16;
        dis_2_sq.rob_idx[1] = 17;
        @(negedge clock);
        retire_2_sq = '0;
        dis_2_sq = '0;
        assert (sq_2_dis.sq_rdy_scnt == 1) 
        else   exit_on_error ("Free count not one");
        @(negedge clock);
        exec_2_sq.st_sq_idx[1] = 3;
        exec_2_sq.st_ex_en[1] = '1;
        exec_2_sq.st_addr[1] = 72;
        exec_2_sq.st_data[1] = 120;
        exec_2_sq.st_mem_size[1] = HALF;
        @(negedge clock);
        exec_2_sq = '0;
        @(negedge clock);
        exec_2_sq.forward_req_en[0] = 1;
        exec_2_sq.forward_addr[0] = 24;
        exec_2_sq.forward_sq_idx[0] = 0;
        exec_2_sq.forward_mem_size[0] = HALF;
        exec_2_sq.forward_req_en[1] = 1;
        exec_2_sq.forward_addr[1] = 72;
        exec_2_sq.forward_sq_idx[1] = 3;
        exec_2_sq.forward_mem_size[1] = WORD;
        exec_2_sq.forward_req_en[2] = 1;
        exec_2_sq.forward_addr[2] = 74;
        exec_2_sq.forward_sq_idx[2] = 3;
        exec_2_sq.forward_mem_size[2] = HALF;
        exec_2_sq.forward_req_en[3] = 1;
        exec_2_sq.forward_addr[3] = 73;
        exec_2_sq.forward_sq_idx[3] = 3;
        exec_2_sq.forward_mem_size[3] = BYTE;
        // @(negedge clock);
        // @(negedge clock);
        @(posedge clock);
        // $display(sq_2_exec.forward_en[1]);
        // $display(sq_2_exec.forward_data[1]);
        assert (sq_2_exec.forward_en[0] == '1)
        else exit_on_error ("Forward 0 en failed");
        assert (sq_2_exec.forward_data[0] == 12288)
        else exit_on_error ("Forward 0 data failed");
        assert (sq_2_exec.forward_en[1] == '1)
        else exit_on_error ("Forward 1 en failed");
        // $display("Forward 1: %0d", sq_2_exec.forward_data[1]);
        assert (sq_2_exec.forward_data[1] == 6291576) //7,864,416
        else exit_on_error ("Forward 1 data failed");
        assert (sq_2_exec.forward_en[2] == '1)
        else exit_on_error ("Forward 2 en failed");
        assert (sq_2_exec.forward_data[2] == 96)
        else exit_on_error ("Forward 2 data failed");
        assert (sq_2_exec.forward_en[3] == '1)
        else exit_on_error ("Forward 3 en failed");
        assert (sq_2_exec.forward_data[3] == 0)
        else exit_on_error ("Forward 3 data failed");
        // $display("Forward[0] map: %4b", sq_2_exec.forward_byte_en[0]);
        // $display("Forward[1] map: %4b", sq_2_exec.forward_byte_en[1]);
        @(negedge clock);
        exec_2_sq = '0;
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);
        @(negedge clock);


        $display("\n\033[32m@@@ Passed\033[0m\n");
        $finish;
    end
endmodule