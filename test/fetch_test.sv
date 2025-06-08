`include "sys_defs.svh"

module fetch_test;
    logic   clock, reset;
    logic   DEBUG = 1;
    
    always begin
        #(`CLOCK_PERIOD/2) clock = ~clock;
    end

    fetch f0 (
        .clock,
        .reset
    );

    initial begin
        $finish;
    end
endmodule