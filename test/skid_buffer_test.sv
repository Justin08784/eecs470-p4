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
        .o_dat  (o_dat),

        .dbg    (state_dbg)
    );

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

    task print_skid_state(
        SKID_STATE s
    );
        $display("SKID_STATE {s: %s, vld: %b, rdy: %b, dat: %0d, tmp: %0d}",
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
        $display("\nTest 1: Check reset state");
        chk('{
            s   : PIPE,
            vld : 0,
            rdy : 1,
            dat : '0,
            tmp : '0
        });

        // ---------- Test 2 ---------- //
        $display("\nTest 2: 1w, 0r, PIPE, empty");

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
        $display("\nTest 3: 1w, 0r, PIPE, has 1");

        wr(2);
        @(negedge clock);
        chk('{
            s   : SKID,
            vld : 1,
            rdy : 0,
            dat : 1,
            tmp : 2
        });

        // ---------- Test 4 ---------- //
        $display("\nTest 4: 1w, 1r, SKID, has 2");

        wr(69);
        o_rdy = 1;
        @(negedge clock);
        o_rdy = 0;
        chk('{
            s   : PIPE,
            vld : 1,
            rdy : 1,
            dat : 2,
            tmp : 2
        });

        // ---------- Test 5 ---------- //
        $display("\nTest 5: 1w, 1r, PIPE, has 1");

        wr(3);
        o_rdy = 1;
        @(negedge clock);
        o_rdy = 0;
        chk('{
            s   : PIPE,
            vld : 1,
            rdy : 1,
            dat : 3,
            tmp : 2
        });

        $finish;
    end


endmodule
