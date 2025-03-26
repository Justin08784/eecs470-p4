`include "sys_defs.svh"


module branch_manager (
    BMASK bmask_reg;
    struct packed {
        ADDR PC;
        MAP_TABLE_ENTRY [`NUM_ARCH_REG-1:0] mt;
        struct packed {
            logic [$clog2(DEPTH)-1:0] head;
            // logic [$clog2(DEPTH)-1:0] tail;
            /* Is this enough to checkpoint? Or do you also 
            need the entire state copied? 
            
            Bradley says this is enough. Just head pointer. */
        } fl;
        logic [$clog2(`ROB_SZ)-1:0] rob_tail;
        // logic [$clog2(`LSQ_SZ)-1:0] lsq_tail;
    } [`NUM_BM_CHECKPOINTS-1:0] checkpoints;
);
endmodule
