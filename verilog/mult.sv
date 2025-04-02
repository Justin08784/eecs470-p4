
`include "sys_defs.svh"

typedef struct packed {
    logic [63:0]    sum;
    logic [63:0]    mplier;
    logic [63:0]    mcand;
    MULT_FUNC       func;
    DST             dst;
} MUL_PKT;

// This is a pipelined multiplier that multiplies two 64-bit integers and
// returns the low 64 bits of the result.
// This is not an ideal multiplier but is sufficient to allow a faster clock
// period than straight multiplication.

module mult (
    input clock, reset, flush,
    input DATA rs1, rs2,
    input MULT_FUNC func,
    input DST dst_in,

    input  logic i_vld,  // replacement for start
    output logic i_rdy,  // TODO: set
    input  logic o_rdy, // TODO: set
    output logic o_vld, // replacement for done

    output DATA result,
    output DST dst_out
);
    MUL_PKT [`MULT_STAGES-2:0] internal_pkts;
    logic   [`MULT_STAGES-2:0] internal_o_vlds;
    logic   [`MULT_STAGES-2:0] internal_o_rdys;


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
            dst     : dst_in
        };
    end

    // instantiate an array of mult_stage modules
    // this uses concatenation syntax for internal wiring, see lab 2 slides
    mult_stage mstage [`MULT_STAGES-1:0] (
        .clock  (clock),
        .reset  (reset),
        .flush  (flush),

        .i_dat  ({internal_pkts, i_pkt}),
        .o_dat  ({o_pkt, internal_pkts}),

        .i_rdy  ({internal_o_rdys,i_rdy}),
        .i_vld  ({internal_o_vlds,i_vld}), // forward prev done as next start
        .o_rdy  ({o_rdy,internal_o_rdys}),
        .o_vld  ({o_vld,internal_o_vlds}) // done when the final stage is done
    );

    // Use the high or low bits of the product based on the output func
    assign result = (o_pkt.func == M_MUL)
        ? o_pkt.sum[31:0]
        : o_pkt.sum[63:32];
    
    assign dst_out = o_pkt.dst;

    `ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("");
        end
    end
    `endif // DEBUG

endmodule // mult


module mult_stage (
    input clock, reset, flush,
    input MUL_PKT   i_dat,

    input  logic    i_vld,  // replacement for start
    output logic    i_rdy,  // TODO: set
    input  logic    o_rdy,  // TODO: set
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
            dst     : i_dat.dst
        };
    end

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

    `ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("– sum: %x, mplier: %x, mcand: %x, func: %0d, tag: %x, rob_idx: %x",
                tmp_dat.sum,
                tmp_dat.mplier,
                tmp_dat.mcand,
                tmp_dat.func,
                tmp_dat.dst.tag,
                tmp_dat.dst.rob_idx
            );
        end
    end
    `endif // DEBUG

endmodule // mult_stage
