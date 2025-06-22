`include "sys_defs.svh"

module prf_test();

localparam WIDTH = 32;
localparam DEPTH = PHYS_REG_SZ_R10K;
localparam N = 2;
localparam BYPASS_EN  = 1;

logic clock, reset, flush;
logic         [N-1:0] c_en;
PHYS_REG_IDX  [N-1:0] c_ts; // tags
DATA          [N-1:0] c_vs; // vals
//DATA         [31:0]  state;
logic         [N-1:0] s_en;
PHYS_REG_IDX  [N-1:0] s_t1s;
PHYS_REG_IDX  [N-1:0] s_t2s;
DATA        [N-1:0] s_v1s;
DATA        [N-1:0] s_v2s;

prf #(
    .WIDTH(WIDTH),
    .DEPTH(DEPTH),
    .N(N),
    .BYPASS_EN(BYPASS_EN)
) dut (
    .clock(clock),
    //.reset(reset),
    //.flush(flush),
    .c_en(c_en),
    .c_ts(c_ts),
    .c_vs(c_vs),
    //.state(state),
    .s_en(s_en),
    .s_t1s(s_t1s),
    .s_t2s(s_t2s),
    .s_v1s(s_v1s),
    .s_v2s(s_v2s)
);

always begin
    #(`CLOCK_PERIOD/2.0);
    clock = ~clock;
    $display(" clock %d   | c_en0: %d  c_ts0: %d  c_vs0: %d | c_en1: %d  c_ts1: %d  c_vs1: %d | s_en0: %d   s_t1s0: %d  s_t2s0: %d  s_v1s0: %d  sv2s0: %d  |  s_en1: %d   s_t1s1: %d  s_t2s1: %d  s_v1s1: %d  sv2s1: %d",
                clock,         c_en[0], c_ts[0], c_vs[0],       c_en[1], c_ts[1], c_vs[1],        s_en[0], s_t1s[0], s_t2s[0], s_v1s[0], s_v2s[0],             s_en[1], s_t1s[1], s_t2s[1], s_v1s[1], s_v2s[1]);
end

initial begin
    clock = 1'b0;
    reset = 1'b0;
    flush = 1'b0;
    @(negedge clock);
    @(negedge clock);
    reset = 1'b0;
    flush = 1'b0;

    @(negedge clock);
    c_en[0] = 1'b1;
    c_en[1] = 1'b1;
    c_ts[0] = 'd10;
    c_ts[1] = 'd12;
    c_vs[0] = 'd10;
    c_vs[1] = 'd12;

    @(negedge clock);
    c_en[0] = 1'b1;
    c_en[1] = 1'b1;
    s_en[0] = 1'b1;
    s_en[1] = 1'b0;
    s_t1s[0] = 'd5;
    s_t1s[1] = 'd12;
    s_t2s[0] = 'd10;
    s_t2s[1] = 'd6;

    
    @(negedge clock);
    s_en[0] = 1'b1;
    s_en[1] = 1'b1;


    @(negedge clock);
    c_en[0] = 1'b1;
    c_en[1] = 1'b1;
    c_ts[0] = 'd20;
    c_ts[1] = 'd22;
    c_vs[0] = 'd20;
    c_vs[1] = 'd22;
    s_en[0] = 1'b1;
    s_en[1] = 1'b1;
    s_t1s[0] = 'd15;
    s_t1s[1] = 'd22;
    s_t2s[0] = 'd20;
    s_t2s[1] = 'd16;

    @(negedge clock);
    s_t1s[0] = 'd0;
    s_t1s[1] = 'd22;

    @(negedge clock);
    s_t1s[0] = 'd0;
    s_t1s[1] = 'd0;


    @(negedge clock);
    s_t1s[0] = 'd20;
    s_t1s[1] = 'd0;


    @(negedge clock);
    $finish;







end

endmodule