
// dummy module that synthesizes to a DW barrel
module barrel #(
    parameter DEPTH = 512,
    type VEC = logic [DEPTH-1:0],
    type PTR = logic [$clog2(DEPTH)-1:0]
) (
    input clock,
    input reset,

    input shift,

    input logic wen,
    input logic wbit,

    output VEC o_state

);
    VEC state;
    PTR base;

    assign o_state = state;

    always_ff @(posedge clock) begin
        if (reset) begin
            base <= '0;
            state <= '0;

        end else if (shift) begin
            state <= {state, state} >> shift;

        end else if (wen) begin
            state[base] <= wbit;
            base <= base - 1;

        end
    end

endmodule;