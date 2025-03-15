`include "sys_defs.svh"


module branch_history_table(
    input logic clock, reset,
    input  logic [31:0] branchPC,
    input logic update,
    input logic taken,
    output logic[7:0] branch_history
);

    logic [7:0] bht [255:0];

    always_ff @(posedge clock) begin
        if (reset) begin
            int i;
            for (i = 0; i < 256; i = i + 1)
                bht[i] <= 8'b0;
        end else begin
            bht[branchPC[7:0]] <= {bht[branchPC[7:1]], taken};
            
        end
    end

    assign branch_history = bht[branchPC[7:0]];

endmodule

module global_history_register(
    input logic clock, reset,
    input logic update,
    input logic taken,
    output logic [3:0] globalBH
    always_ff @(posedge clock) begin
            if (reset) begin 
                globalBHR <= 8'b0; 
            else if (update)
                globalBHR <= {globalBHR[6:0], taken}; 
            end
    end
);

endmodule

module pattern_history_table(
    input logic clock, reset,
    input logic [] index,
    input logic update,
    input logic branch_taken,
    output logic prediction
);

    logic [1:0] pht [255:0]; 

    always_ff @(posedge clock) begin
        if (reset) begin
            int i;
            for (i = 0; i < 256; i = i + 1)
                pht[i] <= 2'b01; 
        end else if (update) begin
           
            if (branch_taken && pht[index] != 2'b11)
                pht[index] <= pht[index] + 1;
            else if (!branch_taken && pht[index] != 2'b00)
                pht[index] <= pht[index] - 1;
        end
    end

    
    assign prediction = (pht[index] >= 2'b10);



endmodule
