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

module ppln_skid #(
    type STATUS = enum logic {
        PIPE,
        SKID
    },
    parameter int FLUSH_MODE=SKID_FLUSH_RESET,
    parameter int unsigned WIDTH
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
    output  logic   [WIDTH-1:0] o_dat
);
    STATUS s;
    logic dat_vld, tmp_vld, rdy; 
        // rdy = can we accept data?
    logic [WIDTH-1:0] dat, tmp;
    BMASK dat_msk, tmp_msk;

    logic i_kill, tmp_kill, dat_kill;
    always_comb begin
        unique case (FLUSH_MODE)
        SKID_FLUSH_MASK:    begin
            i_kill  = flush && |(i_msk   & clmsk);
            tmp_kill= flush && |(tmp_msk & clmsk);
            dat_kill= flush && |(dat_msk & clmsk);
        end
        SKID_FLUSH_IGNORE:  begin
            i_kill  = 1'b0;
            tmp_kill= 1'b0;
            dat_kill= 1'b0;
        end
        default:            begin
            i_kill  = flush;
            tmp_kill= flush;
            dat_kill= flush;
        end
        endcase
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            s   <= PIPE;
            rdy <= 1;
            dat <= '0; dat_vld <= 1'b0; dat_msk <= '0;
            tmp <= '0; tmp_vld <= 1'b0; tmp_msk <= '0;
        end else begin
            case (s)
            PIPE: begin // tmp is not full (i.e. at most dat is full)
                if (o_rdy || !(dat_vld && !dat_kill)) begin
                    // normal accept path
                    rdy     <= 1;

                    dat     <= i_dat;
                    dat_vld <= i_vld && !i_kill;
                    dat_msk <= i_msk & ~clmsk;
                end else begin
                    if (i_vld && !i_kill) begin
                        // go SKID
                        s       <= SKID;
                        rdy     <= 0;
                    end

                    dat_msk <= dat_msk & ~clmsk;

                    tmp     <= i_dat;
                    tmp_vld <= i_vld && !i_kill;
                    tmp_msk <= i_msk & ~clmsk;
                end
            end
            SKID: begin // tmp is full
                if (o_rdy || dat_kill) begin
                    // promote tmp to pipe
                    s       <= PIPE;
                    rdy     <= 1;

                    dat     <= tmp;
                    dat_vld <= !tmp_kill; // implicitly: tmp_vld && !tmp_kill (SKID means tmp_vld)
                    dat_msk <= tmp_msk & ~clmsk;

                    tmp_vld <= 1'b0;
                end else begin
                    if (tmp_kill) begin
                        // go to pipe
                        s       <= PIPE;
                        rdy     <= 1;
                    end

                    dat_msk <= dat_msk & ~clmsk;

                    tmp_vld <= !tmp_kill; // implicitly: tmp_vld && !tmp_kill (SKID means tmp_vld)
                    tmp_msk <= tmp_msk & ~clmsk;
                end
            end
            endcase
        end
    end

    always_comb begin
        i_rdy = rdy;
        o_dat = dat;
        o_vld = dat_vld;
        o_msk = dat_msk;
    end
endmodule