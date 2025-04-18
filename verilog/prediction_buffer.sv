`include "sys_defs.svh"

module prediction_buffer #(
    parameter DEPTH = 16
)(
    input  logic        clock,
    input  logic        reset,

    // Enqueue (Prediction stage, 2-wide)
    input  logic        enq_valid0,
    input  logic [31:0] enq_PC0,
    input  logic [7:0]  enq_bhr0,

    input  logic        enq_valid1,
    input  logic [31:0] enq_PC1,
    input  logic [7:0]  enq_bhr1,

    // Dequeue (Retirement stage, 2-wide)
    input  logic        deq_valid0,
    output logic [31:0] deq_PC0,
    output logic [7:0]  deq_bhr0,

    input  logic        deq_valid1,
    output logic [31:0] deq_PC1,
    output logic [7:0]  deq_bhr1,

    output logic        buffer_ready0,
    output logic        buffer_ready1,
    output logic        buffer_full
);

    typedef struct packed {
        logic [31:0] PC;
        logic [7:0]  bhr;
    } pred_record_t;

    pred_record_t buffer [DEPTH];

    logic [$clog2(DEPTH)-1:0] head, tail;
    logic [$clog2(DEPTH+1):0] count;

    // === Output values from head positions
    assign deq_PC0  = buffer[head].PC;
    assign deq_bhr0 = buffer[head].bhr;

    assign deq_PC1  = buffer[(head + 1) % DEPTH].PC;
    assign deq_bhr1 = buffer[(head + 1) % DEPTH].bhr;

    // === Status flags
    assign buffer_ready0 = (count >= 1);
    assign buffer_ready1 = (count >= 2);
    assign buffer_full   = (count >= DEPTH - 1);  // to avoid overfilling


    logic [$clog2(DEPTH)-1:0] new_tail;
    logic [$clog2(DEPTH+1):0] new_count;

    // === Sequential Logic
    always_ff @(posedge clock or posedge reset) begin
        if (reset) begin
            head  <= 0;
            tail  <= 0;
            count <= 0;
        end else begin
            // === Dequeue logic
            if (deq_valid0 && deq_valid1 && count >= 2) begin
                head  <= (head + 2) % DEPTH;
                count <= count - 2;
            end else if (deq_valid0 && count >= 1) begin
                head  <= (head + 1) % DEPTH;
                count <= count - 1;
            end

            // === Enqueue logic (use staging to avoid conflict)

            new_tail  = tail;
            new_count = count;

            if (enq_valid0 && new_count < DEPTH) begin
                buffer[new_tail] <= '{PC: enq_PC0, bhr: enq_bhr0};
                new_tail  = (new_tail + 1) % DEPTH;
                new_count = new_count + 1;
            end

            if (enq_valid1 && new_count < DEPTH) begin
                buffer[new_tail] <= '{PC: enq_PC1, bhr: enq_bhr1};
                new_tail  = (new_tail + 1) % DEPTH;
                new_count = new_count + 1;
            end

            tail  <= new_tail;
            count <= new_count;
        end


        $display("DEQ_PC0 = 0x%h  DEQ_PC1 = 0x%h", deq_PC0, deq_PC1);
        $display("deq_valid0 = %b  deq_valid1 = %b", deq_valid0, deq_valid1);
       /* $display("update_index0 = %b  update_index1 = %b", update_index[0], update_index[1]);
        $display("buffer_ready0 = %b  buffer_ready1 = %b", buffer_ready0, buffer_ready1);
        $display("  prediction[0] = %1b", prediction[0]);
        $display("  prediction[1] = %1b", prediction[1]);

        $display("  globalBHR = %b", globalBHR);
        $display("  fetch_in.PC[0] = %d", fetch_2_pred.correct_PC[0]);
        $display("  fetch_in.PC[1] = %d", fetch_2_pred.correct_PC[1]);*/
    end

endmodule
