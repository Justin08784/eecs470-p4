
`include "sys_defs.svh"

// This is a pipelined multiplier that multiplies two 64-bit integers and
// returns the low 64 bits of the result.
// This is not an ideal multiplier but is sufficient to allow a faster clock
// period than straight multiplication.

module mult (
    input clock, reset, flush,
    input DATA rs1, rs2,
    input MULT_FUNC func,
    input DST dst_in,

    input  logic in_vld,  // replacement for start
    output logic in_rdy,  // TODO: set
    input  logic out_rdy, // TODO: set
    output logic out_vld, // replacement for done

    output DATA result,
    output DST dst_out
);

    MULT_FUNC [`MULT_STAGES-2:0] internal_funcs;
    MULT_FUNC func_out;

    logic [(64*(`MULT_STAGES-1))-1:0] internal_sums, internal_mcands, internal_mpliers;
    logic [`MULT_STAGES-2:0] internal_out_vlds;

    logic [63:0] mcand, mplier, product;
    logic [63:0] mcand_out, mplier_out; // unused, just for wiring

    DST [`MULT_STAGES-2:0] internal_dsts;

    // instantiate an array of mult_stage modules
    // this uses concatenation syntax for internal wiring, see lab 2 slides
    mult_stage mstage [`MULT_STAGES-1:0] (
        .clock (clock),
        .reset (reset),
        .flush (flush),
        .func        ({internal_funcs,   func}),
        .in_vld      ({internal_out_vlds,in_vld}), // forward prev done as next start
        .prev_sum    ({internal_sums,    64'h0}), // start the sum at 0
        .mplier      ({internal_mpliers, mplier}),
        .mcand       ({internal_mcands,  mcand}),
        .dst         ({internal_dsts,    dst_in}),
        .product_sum ({product,    internal_sums}),
        .next_mplier ({mplier_out, internal_mpliers}),
        .next_mcand  ({mcand_out,  internal_mcands}),
        .next_func   ({func_out,   internal_funcs}),
        .next_dst    ({dst_out,    internal_dsts}),
        .out_vld     ({out_vld,    internal_out_vlds}) // done when the final stage is done
    );

    // Sign-extend the multiplier inputs based on the operation
    always_comb begin
        case (func)
            M_MUL, M_MULH, M_MULHSU: mcand = {{(32){rs1[31]}}, rs1};
            default:                 mcand = {32'b0, rs1};
        endcase
        case (func)
            M_MUL, M_MULH: mplier = {{(32){rs2[31]}}, rs2};
            default:       mplier = {32'b0, rs2};
        endcase
    end

    // Use the high or low bits of the product based on the output func
    assign result = (func_out == M_MUL) ? product[31:0] : product[63:32];

endmodule // mult


module mult_stage (
    input clock, reset, flush,
    input [63:0] prev_sum, mplier, mcand,
    input DST dst,
    input MULT_FUNC func,

    input  logic in_vld,  // replacement for start
    output logic in_rdy,  // TODO: set
    input  logic out_rdy, // TODO: set
    output logic out_vld, // replacement for done

    output logic [63:0] product_sum, next_mplier, next_mcand,
    output MULT_FUNC next_func,
    output DST next_dst
);

    parameter SHIFT = 64/`MULT_STAGES;

    logic [63:0] partial_product, shifted_mplier, shifted_mcand;

    assign partial_product = mplier[SHIFT-1:0] * mcand;

    assign shifted_mplier = {SHIFT'('b0), mplier[63:SHIFT]};
    assign shifted_mcand = {mcand[63-SHIFT:0], SHIFT'('b0)};

    always_ff @(posedge clock) begin
        product_sum <= prev_sum + partial_product;
        next_mplier <= shifted_mplier;
        next_mcand  <= shifted_mcand;
        next_func   <= func;
        next_dst    <= dst;
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            out_vld <= 1'b0;
        end else begin
            out_vld <= in_vld;
        end
    end

endmodule // mult_stage
