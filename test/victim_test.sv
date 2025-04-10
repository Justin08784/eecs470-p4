`include "sys_defs.svh"


module victim_test();
    localparam sz = 4;
    typedef struct packed {
        logic       [sz-1:0]        vld;
        logic       [sz-1:0][15:3]  tag;
        MEM_BLOCK   [sz-1:0]        dat;
        logic       [sz-1:0][1:0]   prio;
    } STATE;

    logic clock;
    logic reset;

    // evicted block
    logic   wen;
    ADDR    waddr;
    DATA    wdat;

    logic   ren;
    ADDR    raddr;
    DATA    rdat;
    logic   rvld;

    STATE   dbg;
    
    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    // always @(posedge clock) begin
    //     if (DEBUG) begin
    //         // $display()
    //     end
    // end
    
    // FIFO instance
    victim_cache dut (
        .clock  (clock),
        .reset  (reset),

        .wen    (wen),
        .waddr  (waddr),
        .wdat   (wdat),

        .ren    (ren),
        .raddr  (raddr),
        .rdat   (rdat),
        .rvld   (rvld),

        .dbg    (dbg)
    );

    task wr(
        input int v,
        input int addr
    );
        wen     = 1;
        waddr   = addr;
        wdat    = v;
    endtask

    task rd(
        input int addr
    );
        ren     = 1;
        raddr   = addr;
    endtask

    task clr_all();
        wen     = 0;
        waddr   = '0;
        wdat    = '0;

        ren     = 0;
        raddr   = '0;
    endtask

    task do_reset();
        reset = 1;
        @(negedge clock);
        reset = 0;
    endtask


    task print_state(
        STATE s
    );
        $display("== CACHE ==");
        for (int i = 0; i < sz; ++i) begin
            $display("cache[%1d]: vld=%b, tag=%x, dat=%x, prio=%1d",
                i,
                s.vld[i],
                s.tag[i],
                s.dat[i],
                s.prio[i]
            );
        end
    endtask

    // task chk(
    //     SKID_STATE expected
    // );
    //     logic match = state_dbg == expected
    //         && i_rdy == expected.rdy
    //         && o_dat == expected.dat
    //         && o_vld == expected.vld;
    //     if (state_dbg != expected) begin
    //         $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
    //         $display("dbg");
    //         print_skid_state(state_dbg);
    //         $display("expected");
    //         print_skid_state(expected);
    //         // $display("\033[31mError: %0s\033[0m\n\n", msg);
    //         $finish();
    //     end
    // endtask

    function automatic logic[13:0] append3(logic[10:0] addr);
        return {addr, 3'b000};
    endfunction

    initial begin
        $display("\nStart Testbench");
        clock = 0;
        reset = 1;
        clr_all();
        do_reset();
        @(negedge clock);
        print_state(dbg);

        // ---------- Test 1 ---------- //
        wr(1, append3(1));
        @(negedge clock);
        print_state(dbg);
        wr(2, append3(2));
        @(negedge clock);
        print_state(dbg);
        wr(3, append3(3));
        @(negedge clock);
        print_state(dbg);
        wr(4, append3(4));
        @(negedge clock);
        print_state(dbg);
        wr(5, append3(5));
        @(negedge clock);
        print_state(dbg);

        clr_all();


        $finish;
    end


endmodule
