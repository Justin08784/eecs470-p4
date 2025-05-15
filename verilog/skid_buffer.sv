`include "sys_defs.svh"

module flop #(
    parameter int FLUSH_MODE=SKID_FLUSH_RESET,
    parameter int unsigned WIDTH=1
) (
    input   clock, 
    input   reset,
    input   flush,
    BMASK   clmsk, // kill mask iff flush high

    input   logic   i_vld,
    input   BMASK   i_msk,
    input   logic   [WIDTH-1:0] i_dat,

    output  logic   o_vld,
    output  BMASK   o_msk,
    output  logic   [WIDTH-1:0] o_dat
);
    logic vld;
    BMASK msk;
    logic [WIDTH-1:0] dat;

    logic kill;
    always_comb begin
        unique case (FLUSH_MODE)
            SKID_FLUSH_MASK:    kill = flush && |(i_msk & clmsk);
            SKID_FLUSH_IGNORE:  kill = 1'b0;
            default:            kill = flush;
        endcase
    end

    always_ff @(posedge clock) begin
        if (reset || kill) begin
            vld <= 0;
            msk <= '0;
            dat <= '0;
        end else begin
            vld <= i_vld;
            msk <= i_msk & ~clmsk;
            dat <= i_dat;
        end
    end

    assign o_vld = vld;
    assign o_msk = msk;
    assign o_dat = dat;
endmodule

module skid #(
    parameter int unsigned WIDTH=1,
    parameter int FLUSH_MODE=SKID_FLUSH_RESET,
    parameter logic ENABLE_SNOOP = `FALSE
) (
    input   clock, 
    input   reset,
    input   flush,
    BMASK   clmsk, // kill mask iff flush high

    input   logic   i_vld,
    output  logic   i_rdy,
    input   BMASK   i_msk,
    input   logic   [WIDTH-1:0] i_dat,

    output  logic   o_vld,
    input   logic   o_rdy,
    output  BMASK   o_msk,
    output  logic   [WIDTH-1:0] o_dat,

    input   logic   [WIDTH-1:0] i_snoop // post-snooping
);
    logic vld; 
        // vld = is dat, i.e. pipeline reg, busy/occupied?
        // rdy = can we accept data?
    BMASK msk;
    logic [WIDTH-1:0] dat;

    always_comb begin
        i_rdy = !vld || o_rdy;
        o_dat = dat;
        o_vld = vld;
    end

    logic i_kill, dat_kill;
    always_comb begin
        unique case (FLUSH_MODE)
        SKID_FLUSH_MASK:    begin
            i_kill  = flush && |(i_msk & clmsk);
            dat_kill= flush && |(msk   & clmsk);
        end
        SKID_FLUSH_IGNORE:  begin
            i_kill  = 1'b0;
            dat_kill= 1'b0;
        end
        default:            begin
            i_kill  = flush;
            dat_kill= flush;
        end
        endcase
    end

    always_ff @(posedge clock) begin
        // ---- clear conditions ----
        if ( reset
        || ( i_rdy && i_kill)
        || (!i_rdy && dat_kill)) begin
            vld <= 1'b0;
            msk <= '0;
            dat <= '0;
        // ---- normal acceptance path ----
        end else if (i_rdy) begin // i_rdy && !i_kill
            vld <= i_vld;
            msk <= i_msk & ~clmsk;
            dat <= i_dat;
        // ---- hold / snoop path ----
        end else begin
            assert (vld && !o_rdy) else $fatal("skid: snoop: unexpected");
            msk <= msk & ~clmsk;
            if (ENABLE_SNOOP)
                dat <= i_snoop;
        end
    end
endmodule

typedef enum logic {
    PIPE = 0,
    SKID = 1
} STATUS;

module ppln_skid #(
    parameter int unsigned WIDTH
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
                rdy <= 1;
            end else if (i_vld) begin
                tmp <= i_dat;
                rdy <= 0;
                s   <= SKID;
            end
            end
            SKID: begin // tmp is full
            if (o_rdy) begin
                dat <= tmp;
                vld <= 1;
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