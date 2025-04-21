
`include "sys_defs.svh"

typedef struct packed {
    logic [63:0]    sum;
    logic [63:0]    mplier;
    logic [63:0]    mcand;
    MULT_FUNC       func;
    PHYS_REG_IDX    t;
    ROB_IDX         rob_idx;
} MUL_PKT;

typedef enum logic[1:0] {
    O_NONE    = 0, // passthrough
    O_SKID    = 1, // combinational backpressure, registered forward pressure
    O_PSKID   = 2, // registered back AND forward pressure (but needs 2 regs)
    O_FLOP    = 3  // no handshake; advance unconditionally (i.e. simple flop)
} OUT_MODE;

// This is a pipelined multiplier that multiplies two 64-bit integers and
// returns the low 64 bits of the result.
// This is not an ideal multiplier but is sufficient to allow a faster clock
// period than straight multiplication.

module mult #(
    parameter int unsigned ID
) (
    input clock, reset, flush,
    input DATA rs1, rs2,
    input MULT_FUNC func,
    input PHYS_REG_IDX  i_t,
    input ROB_IDX       i_rob_idx,

    input  logic i_vld,  // replacement for start
    output logic i_rdy,
    input  logic o_rdy,
    output logic o_vld, // replacement for done

    // lines for early CDB arbitration
    output logic cdb_req,
    output PHYS_REG_IDX ctag_t,
    input  logic cdb_gnt,

    output DATA result,
    output PHYS_REG_IDX  o_t,
    output ROB_IDX       o_rob_idx
);
    logic [63:0] i_mcand, i_mplier;
    MUL_PKT i_pkt, o_pkt;
    
    // Sign-extend the multiplier inputs based on the operation
    always_comb begin
        case (func)
            M_MUL, M_MULH, M_MULHSU: i_mcand = {{(32){rs1[31]}}, rs1};
            default:                 i_mcand = {32'b0, rs1};
        endcase
        case (func)
            M_MUL, M_MULH: i_mplier = {{(32){rs2[31]}}, rs2};
            default:       i_mplier = {32'b0, rs2};
        endcase

        i_pkt = '{
            sum     : 64'h0,
            mplier  : i_mplier,
            mcand   : i_mcand,
            func    : func,
            t       : i_t,
            rob_idx : i_rob_idx
        };
    end
    
    // instantiate an array of mult_stage modules
    // this uses concatenation syntax for internal wiring, see lab 2 slides
    logic   [`MULT_STAGES:0] vlds;
    logic   [`MULT_STAGES:0] rdys;
    MUL_PKT [`MULT_STAGES:0] pkts;

    always_comb begin
        vlds[0] = i_vld;
        i_rdy   = rdys[0];
        pkts[0] = i_pkt;

        o_vld               = vlds[`MULT_STAGES];
        rdys[`MULT_STAGES]  = o_rdy;
        o_pkt               = pkts[`MULT_STAGES];
    end

    for (genvar i = 0; i < `MULT_STAGES; ++i) begin : gen_stages
        if (i < `MULT_STAGES-4) begin
            mult_stage #(
                .MODE(O_SKID)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld(vlds[i]),
                .i_rdy(rdys[i]),
                .i_dat(pkts[i]),
                .o_vld(vlds[i+1]),
                .o_rdy(rdys[i+1]),
                .o_dat(pkts[i+1])
            );

        end else if (i == `MULT_STAGES-4) begin
            // stage just before CDB arbiter; guard upstream with ppln_skid
            mult_stage #(
                .MODE(O_PSKID)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld(vlds[i]),
                .i_rdy(rdys[i]),
                .i_dat(pkts[i]),
                .o_vld(cdb_req),
                .o_rdy(cdb_gnt),
                .o_dat(pkts[i+1])
            );
            assign ctag_t = pkts[i+1].t;

        end else if (i == `MULT_STAGES-3) begin
            // stage just after CDB arbiter; since arb. is done, may advance unconditionally
            mult_stage #(
                .MODE(O_FLOP)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld(cdb_gnt),
                .i_dat(pkts[i]),
                .o_vld(vlds[i+1]),
                .o_dat(pkts[i+1])
            );

        end else if (i < `MULT_STAGES-1) begin
            mult_stage #(
                .MODE(O_FLOP)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld(vlds[i]),
                .i_dat(pkts[i]),
                .o_vld(vlds[i+1]),
                .o_dat(pkts[i+1])
            );

        end else if (i == `MULT_STAGES-1) begin
            // do not buffer here; latch result directly into CDB data bus (cdat_out)

            mult_stage #(
                .MODE(O_NONE)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),

                .i_vld(vlds[i]),
                .i_dat(pkts[i]),
                .o_vld(vlds[i+1]),
                .o_dat(pkts[i+1])
            );

        end else begin
            $error("mult OUT_MODE config: This case should be impossible.");
            $fatal;
        end
    end

    // Use the high or low bits of the product based on the output func
    always_comb begin
        result = (o_pkt.func == M_MUL)
            ? o_pkt.sum[31:0]
            : o_pkt.sum[63:32];
        o_t         = o_pkt.t;
        o_rob_idx   = o_pkt.rob_idx;
    end

    // `ifdef DEBUG
    // always_ff @(posedge clock) begin
    //     if (!reset && ID == 0) begin
    //         $display("  %3d | >> mul%0d >>", $time, ID);
    //         for (int unsigned i = 0; i < `MULT_STAGES+1; ++i) begin
    //             $display("– sum: %x, mplier: %x, mcand: %x, func: %0d, tag: %2d, rob_idx: %2d",
    //                 pkts[i].sum,
    //                 pkts[i].mplier,
    //                 pkts[i].mcand,
    //                 pkts[i].func,
    //                 pkts[i].t,
    //                 pkts[i].rob_idx
    //             );
    //         end
    //         $display("  %3d | << mul%0d <<", $time, ID);
    //     end
    // end
    // `endif // DEBUG

endmodule // mult


module mult_stage #(
    parameter MODE = O_SKID
) (
    input clock, reset, flush,
    input MUL_PKT   i_dat,

    input  logic    i_vld,  // replacement for start
    output logic    i_rdy,
    input  logic    o_rdy,
    output logic    o_vld,  // replacement for done

    output MUL_PKT  o_dat
);

    parameter SHIFT = 64/`MULT_STAGES;

    logic [63:0] partial_product, shifted_mplier, shifted_mcand;
    MUL_PKT tmp_dat;
    always_comb begin
        partial_product = i_dat.mplier[SHIFT-1:0] * i_dat.mcand;
        shifted_mplier  = {SHIFT'('b0), i_dat.mplier[63:SHIFT]};
        shifted_mcand   = {i_dat.mcand[63-SHIFT:0], SHIFT'('b0)};

        tmp_dat = '{
            sum     : i_dat.sum + partial_product,
            mplier  : shifted_mplier,
            mcand   : shifted_mcand,
            func    : i_dat.func,
            t       : i_dat.t,
            rob_idx : i_dat.rob_idx
        };
    end

    generate
        case (MODE)
        O_NONE: begin
            assign i_rdy = o_rdy;
            assign o_vld = i_vld;
            assign o_dat = tmp_dat;
        end

        O_SKID: begin
            skid #(
                .WIDTH($bits(MUL_PKT))
            ) skid_0 (
                .clock(clock),
                .reset(reset),
                .flush(flush),
                
                .i_vld(i_vld),
                .i_rdy(i_rdy),
                .i_dat(tmp_dat),

                .o_vld(o_vld),
                .o_rdy(o_rdy),
                .o_dat(o_dat)
            );
        end

        O_PSKID: begin
            ppln_skid #(
                .WIDTH($bits(MUL_PKT))
            ) skid_0 (
                .clock(clock),
                .reset(reset),
                .flush(flush),
                
                .i_vld(i_vld),
                .i_rdy(i_rdy),
                .i_dat(tmp_dat),

                .o_vld(o_vld),
                .o_rdy(o_rdy),
                .o_dat(o_dat)
            );
        end

        O_FLOP: begin
            assign i_rdy = 1'b1;

            flop #(
                .WIDTH($bits(MUL_PKT))
            ) flop_0 (
                .clock(clock),
                .reset(reset),
                .flush(flush),
                
                .i_vld(i_vld),
                .i_dat(tmp_dat),

                .o_vld(o_vld),
                .o_dat(o_dat)
            );
        end
        endcase
    endgenerate

endmodule // mult_stage
