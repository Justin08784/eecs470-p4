`include "sys_defs.svh"


module skid_buffer_test();
    localparam WIDTH = $bits(int);
    typedef struct packed {
        logic s;
        logic vld, rdy;
        logic [WIDTH-1:0] dat, tmp;
    } SKID_STATE;
    typedef enum logic {
        PIPE = 0,
        SKID = 1
    } STATUS;

    logic   clock, reset;
    logic   i_vld, i_rdy, o_vld, o_rdy;
    logic   [WIDTH-1:0] i_dat, o_dat;
    SKID_STATE state_dbg;
    logic   DEBUG = 1;
    
    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    always @(posedge clock) begin
        if (DEBUG) begin
            // $display()
        end
    end
    
    // FIFO instance
    ppln_skid #(
        .WIDTH(WIDTH)
    ) dut (
        .clock  (clock),
        .reset  (reset),
        .flush  ('0),

        .i_vld  (i_vld),
        .i_rdy  (i_rdy),
        .i_dat  (i_dat),

        .o_vld  (o_vld),
        .o_rdy  (o_rdy),
        .o_dat  (o_dat)
    );

    always_comb begin
        state_dbg = '{
            s   : dut.s,
            vld : dut.dat_vld,
            rdy : dut.rdy,
            dat : dut.dat,
            tmp : dut.tmp
        };
    end

    task wr(
        input int v
    );
        i_vld = 1;
        i_dat = v;
    endtask

    task stall();
        o_rdy = 0;
    endtask
    task unstall();
        o_rdy = 1;
    endtask

    task clr_all();
        i_vld = 0;
        i_dat = 'hdeadbeef;
        o_rdy = 0;
    endtask

    task do_reset();
        reset = 1;
        @(negedge clock);
        reset = 0;
    endtask


    task print_skid_state(
        SKID_STATE s
    );
        $display("SKID_STATE {s: %s, vld: %b, rdy: %b, dat: %x, tmp: %x}",
            s.s == 0 ? "PIPE" : "SKID",
            s.vld,
            s.rdy,
            s.dat,
            s.tmp
        );
    endtask

    task chk(
        SKID_STATE expected
    );
        logic match = state_dbg == expected
            && i_rdy == expected.rdy
            && o_dat == expected.dat
            && o_vld == expected.vld;
        if (state_dbg != expected) begin
            $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
            $display("dbg");
            print_skid_state(state_dbg);
            $display("expected");
            print_skid_state(expected);
            // $display("\033[31mError: %0s\033[0m\n\n", msg);
            $finish();
        end
    endtask

    task setup_pipe_empty();
        clr_all();
        do_reset();
    endtask

    task setup_pipe_has1();
        clr_all();
        do_reset();

        wr(1);
        @(negedge clock);
        clr_all();
    endtask

    task setup_skid_has2();
        clr_all();
        do_reset();

        wr(1);
        @(negedge clock);
        wr(2);
        @(negedge clock);
        clr_all();
    endtask

    initial begin
        $display("\nStart Testbench");
        clock = 0;
        reset = 1;
        i_vld = 0;
        o_rdy = 0;
        i_dat = '0;

        @(negedge clock);
        reset = 0;
        @(negedge clock);

        // ---------- Test 1 ---------- //
        $display("\nTest 1: Reset state");
        chk('{
            s   : PIPE,
            vld : 0,
            rdy : 1,
            dat : '0,
            tmp : '0
        });

        // ---------- Test 2 ---------- //
        $display("\nTest 2: from PIPE, empty");
        setup_pipe_empty();
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 0,
            rdy : 1,
            dat : 'hdeadbeef,
            tmp : '0
        });

        setup_pipe_empty();
        o_rdy = 1;
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 0,
            rdy : 1,
            dat : 'hdeadbeef,
            tmp : '0
        });

        setup_pipe_empty();
        wr(1);
        o_rdy = 1;
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 1,
            rdy : 1,
            dat : 1,
            tmp : '0
        });

        setup_pipe_empty();
        wr(1);
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 1,
            rdy : 1,
            dat : 1,
            tmp : '0
        });

        // ---------- Test 3 ---------- //
        $display("\nTest 3: from PIPE, has 1");
        setup_pipe_has1();
        $display("just before:");
        print_skid_state(state_dbg);
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 1,
            rdy : 1,
            dat : 1,
            tmp : '0
        });

        setup_pipe_has1();
        o_rdy = 1;
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 0,
            rdy : 1,
            dat : 'hdeadbeef,
            tmp : '0
        });

        setup_pipe_has1();
        wr(2);
        @(negedge clock);
        chk('{
            s   : SKID,
            vld : 1,
            rdy : 0,
            dat : 1,
            tmp : 2
        });

        setup_pipe_has1();
        o_rdy = 1;
        wr(2);
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 1,
            rdy : 1,
            dat : 2,
            tmp : '0
        });

        // ---------- Test 4 ---------- //
        $display("\nTest 4: from SKID, has 2");
        setup_skid_has2();
        @(negedge clock);
        chk('{
            s   : SKID,
            vld : 1,
            rdy : 0,
            dat : 1,
            tmp : 2
        });

        setup_skid_has2();
        o_rdy = 1;
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 1,
            rdy : 1,
            dat : 2,
            tmp : 2
        });

        setup_skid_has2();
        wr(3);
        @(negedge clock);
        chk('{
            s   : SKID,
            vld : 1,
            rdy : 0,
            dat : 1,
            tmp : 2
        });

        setup_skid_has2();
        o_rdy = 1;
        wr(3);
        @(negedge clock);
        chk('{
            s   : PIPE,
            vld : 1,
            rdy : 1,
            dat : 2,
            tmp : 2
        });
        
        $finish;
    end


endmodule
