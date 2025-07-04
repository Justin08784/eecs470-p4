`include "sys_defs.svh"

module foo_test;
    logic clock, reset, wen;
    logic [511:0] wval, rval;

    foo foo0 (
        .clock,
        .reset,

        .wen,
        .wval,
        .rval
    );

    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end


    initial begin
        reset = 0;
        clock = 0;
        wen = 0;
        @(negedge clock);
        @(negedge clock);


        repeat(100) begin
            // $display("rval: %b wen: %b", rval, wen);
            @(negedge clock);
        end

        $display("v: %b", rval);

        $finish;
    end



endmodule