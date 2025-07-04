module foo (
    input   clock,
    input   reset,

    input   logic   wen,
    input   logic   [511:0]   wval,
    output  logic   [511:0]   rval
);
    logic [511:0] v;
    assign rval = v;

    always_ff @(posedge clock) begin
        if (wen)
            v <= wval;
    end
endmodule