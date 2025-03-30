`include "sys_defs.svh"

module prediction_buffer #(
    parameter DEPTH = 8
)(
    input  logic        clock,
    input  logic        reset,

    // Enqueue at prediction time
    input  logic        enq_valid,
    input  logic [31:0] enq_PC,
    input  logic [7:0]  enq_bhr,

    // Dequeue at update time
    input  logic        deq_valid,
    input  logic [31:0] deq_PC,  // for sanity checks or matching
    output logic [7:0]  deq_bhr,
    output logic        deq_ready
);

    typedef struct packed {
        logic [31:0] PC;
        logic [7:0]  bhr;
    } pred_record_t;

    pred_record_t buffer [DEPTH];
    int head, tail;
    logic full, empty;

    // Initialize
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            head  <= 0;
            tail  <= 0;
            full  <= 0;
            empty <= 1;
        end else begin
            // Enqueue
            if (enq_valid && !full) begin
                buffer[tail].PC  <= enq_PC;
                buffer[tail].bhr <= enq_bhr;
                tail <= (tail + 1) % DEPTH;
            end

            // Dequeue
            if (deq_valid && !empty) begin
                head <= (head + 1) % DEPTH;
            end

            // Update full/empty flags
            full  <= ((tail + 1) % DEPTH == head);
            empty <= (head == tail);
        end
    end

    assign deq_bhr   = buffer[head].bhr;
    assign deq_ready = !empty;

endmodule
