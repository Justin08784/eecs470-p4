module bmask_table (
    input  logic        clk, rst,
    input  logic [4:0]  branchTag,     // 5-bit tag (ROB index) for the branch
    input  logic [31:0] branchPC,      // Branch PC
    input  logic        predictTaken,  // Predicted branch outcome
    input  logic [4:0]  instTag,       // ROB tag of an instruction in the pipeline
    input  logic [31:0] instPC,        // PC of the instruction
    input  logic        branchResolved,// High when branch is resolved in EX
    input  logic        actualTaken,   // Actual branch outcome from EX stage
    input  logic        robCommit,     // ROB commits the branch (final retirement)
    output logic        mispredict,    // High if misprediction detected
    output logic        flush,         // Flush dependent instructions
    output logic [31:0] correctPC      // Correct PC for pipeline recovery
);
    logic [7:0] bmask_table [31:0]; // Indexed by ROB tag (32-entry BMask Table)

    

endmodule