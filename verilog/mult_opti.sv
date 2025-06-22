`include "sys_defs.svh"

typedef struct packed {
    logic [63:0]    sum;
    logic [63:0]    mcand;
    MUL_FUNC        func;
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

/* This is the standard pipelined multiplier provided in EEECS 470 but equipped
with some explicit casting and bit-saving measures that would presumably
be illegal in EECS 470.

Dramatically improves area and clock period, over the standard.
In commit, cfeb29744890778d6ec90262c31879f8e59021f9, core synthesis...
- At 4.7ns violated slack by 0.1ns
- At 5.0ns saved 10^6 units of area, a ~12.5% decrease in the entire core
(TODO: redo these measurements for mult only, rather than entire core?)
*/

module mult #(
    parameter int unsigned ID
) (
    input clock, reset, flush,
    input BMASK clmsk,

    input DATA rs1, rs2,
    input MUL_FUNC func,
    input BMASK         i_bmask,
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
            // mplier  : i_mplier,
            mcand   : i_mcand,
            func    : func,
            t       : i_t,
            rob_idx : i_rob_idx
        };
    end
    
    // instantiate an array of mult_stage modules
    // this uses concatenation syntax for internal wiring, see lab 2 slides
    logic   [MUL_STAGES:0] vlds;
    BMASK   [MUL_STAGES:0] msks;
    logic   [MUL_STAGES:0] rdys;
    MUL_PKT [MUL_STAGES:0] pkts;
    logic   [MUL_STAGES:0][63:0] mpls;

    always_comb begin
        vlds[0] = i_vld;
        msks[0] = i_bmask;
        mpls[0] = i_mplier;
        i_rdy   = rdys[0];
        pkts[0] = i_pkt;

        o_vld               = vlds[MUL_STAGES];
        rdys[MUL_STAGES]   = o_rdy;
        o_pkt               = pkts[MUL_STAGES];
    end

    for (genvar i = 0; i < MUL_STAGES; ++i) begin : gen_stages
        if (i < MUL_STAGES-4) begin
            mult_stage #(
                .POS(i),
                .MODE(O_SKID)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld(vlds[i]),
                .i_rdy(rdys[i]),
                .i_msk(msks[i]),
                .i_mpl(mpls[i]),
                .i_dat(pkts[i]),

                .o_vld(vlds[i+1]),
                .o_rdy(rdys[i+1]),
                .o_msk(msks[i+1]),
                .o_mpl(mpls[i+1]),
                .o_dat(pkts[i+1])
            );

        end else if (i == MUL_STAGES-4) begin
            // stage just before CDB arbiter; guard upstream with ppln_skid
            mult_stage #(
                .POS(i),
                .MODE(O_PSKID)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld(vlds[i]),
                .i_rdy(rdys[i]),
                .i_msk(msks[i]),
                .i_mpl(mpls[i]),
                .i_dat(pkts[i]),

                .o_vld(cdb_req),
                .o_rdy(cdb_gnt),
                .o_msk(msks[i+1]),
                .o_mpl(mpls[i+1]),
                .o_dat(pkts[i+1])
            );
            assign ctag_t = pkts[i+1].t;

        end else if (i == MUL_STAGES-3) begin
            // stage just after CDB arbiter; since arb. is done, may advance unconditionally
            mult_stage #(
                .POS(i),
                .MODE(O_FLOP)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld(cdb_gnt),
                .i_msk(msks[i]),
                .i_mpl(mpls[i]),
                .i_dat(pkts[i]),

                .o_vld(vlds[i+1]),
                .o_msk(msks[i+1]),
                .o_mpl(mpls[i+1]),
                .o_dat(pkts[i+1])
            );

        end else if (i < MUL_STAGES-1) begin
            mult_stage #(
                .POS(i),
                .MODE(O_FLOP)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld(vlds[i]),
                .i_msk(msks[i]),
                .i_mpl(mpls[i]),
                .i_dat(pkts[i]),

                .o_vld(vlds[i+1]),
                .o_msk(msks[i+1]),
                .o_mpl(mpls[i+1]),
                .o_dat(pkts[i+1])
            );

        end else if (i == MUL_STAGES-1) begin
            // do not buffer here; latch result directly into CDB data bus (cdat_out)

            mult_stage #(
                .POS(i),
                .MODE(O_NONE)
            ) mstage (
                .clock (clock),
                .reset (reset),
                .flush (flush),
                .clmsk,

                .i_vld(vlds[i]),
                .i_msk(msks[i]),
                .i_mpl(mpls[i]),
                .i_dat(pkts[i]),

                .o_vld(vlds[i+1]),
                .o_msk(msks[i+1]),
                .o_mpl(mpls[i+1]),
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
    //         for (int unsigned i = 0; i < MUL_STAGES+1; ++i) begin
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
    parameter POS,
    parameter MODE = O_SKID,
    localparam SHIFT = 64/MUL_STAGES,
    localparam ub = SHIFT*(POS+1),
    localparam lb = SHIFT*POS
) (
    input clock, reset, flush,
    input BMASK     clmsk,

    input MUL_PKT   i_dat,
    input logic[63:0] i_mpl,

    input  logic    i_vld,  // replacement for start
    input  BMASK    i_msk,
    output logic    i_rdy,

    input  logic    o_rdy,
    output BMASK    o_msk,
    output logic    o_vld,  // replacement for done

    output logic[63:0] o_mpl,
    output MUL_PKT  o_dat
);
    logic [63:0] sum;
    logic [63-lb:0] pp;
    MUL_PKT tmp_dat;

    typedef struct packed {
        MUL_PKT         dat;
        logic [63:ub-1] mpl;
    } WRAP;
    WRAP i_tmp, o_tmp;

    always_comb begin
        pp = i_mpl[SHIFT-1:0] * i_dat.mcand;
        sum = i_dat.sum;
        sum[63:lb] = i_dat.sum[63:lb] + pp;

        tmp_dat = '{
            sum     : sum,
            mcand   : i_dat.mcand,

            func    : i_dat.func,
            t       : i_dat.t,
            rob_idx : i_dat.rob_idx
        };

        i_tmp = '{
            dat : tmp_dat,
            mpl : i_mpl[63:SHIFT]
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
                .WIDTH($bits(WRAP))
            ) skid_0 (
                .clock,
                .reset,
                .flush,
                .clmsk,
                
                .i_vld,
                .i_rdy,
                .i_msk,
                .i_dat(i_tmp),

                .o_vld,
                .o_rdy,
                .o_msk,
                .o_dat(o_tmp)
            );

            assign o_dat = o_tmp.dat;
            assign o_mpl = o_tmp.mpl;
        end

        O_PSKID: begin
            ppln_skid #(
                .WIDTH($bits(WRAP))
            ) skid_0 (
                .clock,
                .reset,
                .flush,
                .clmsk,
                
                .i_vld,
                .i_rdy,
                .i_msk,
                .i_dat(i_tmp),

                .o_vld,
                .o_rdy,
                .o_msk,
                .o_dat(o_tmp)
            );

            assign o_dat = o_tmp.dat;
            assign o_mpl = o_tmp.mpl;
        end

        O_FLOP: begin
            assign i_rdy = 1'b1;

            flop #(
                .WIDTH($bits(WRAP))
            ) flop_0 (
                .clock,
                .reset,
                .flush,
                .clmsk,
                
                .i_vld,
                .i_msk,
                .i_dat(i_tmp),

                .o_vld,
                .o_msk,
                .o_dat(o_tmp)
            );

            assign o_dat = o_tmp.dat;
            assign o_mpl = o_tmp.mpl;
        end
        endcase
    endgenerate

endmodule // mult_stage
