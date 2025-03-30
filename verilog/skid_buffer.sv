`include "sys_defs.svh"

typedef enum logic {
    PIPE = 0,
    SKID = 1
} STATUS;

module ppln_skid #(
    parameter int unsigned WIDTH=2
) (
    input   clock, 
    input   reset,
    input   flush,

    input   logic   i_vld,
    output  logic   i_rdy,
    input   logic   [WIDTH-1:0] i_dat,

    output  logic   o_vld,
    input   logic   o_rdy,
    output  logic   [WIDTH-1:0] o_dat
);
    STATUS s;
    logic vld, rdy; 
        // vld = is dat, i.e. pipeline reg, busy/occupied?
        // rdy = can we accept data?
    logic [WIDTH-1:0] dat, tmp;

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            s   <= PIPE;
            vld <= 0;
            rdy <= 1;
            dat <= '0;
            tmp <= '0;
        end else begin
            case (s)
            PIPE: begin // tmp is not full (i.e. at most dat is full)
            if (o_rdy || !vld) begin
                dat <= i_dat;
                vld <= i_vld;
                // rdy <= 1; // necessary?
            end else if (vld) begin
                tmp <= i_dat;
                rdy <= 0;
                s   <= SKID;
            end
            end
            SKID: begin // tmp is full
            if (o_rdy) begin
                dat <= tmp;
                vld <= 1; // necessary?
                rdy <= 1;
                s   <= PIPE;
            end
            end
            endcase
        end
    end

    always_comb begin
        i_rdy = rdy;
        o_dat = dat;
        o_vld = vld;
    end
endmodule