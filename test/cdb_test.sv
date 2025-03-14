`include "sys_defs.svh"

module cdb_testbench;
    localparam N=`N;

    // constants
    // signals
    logic clock;
    logic reset;
    // logic flush;
    logic failed;

    PHYS_REG_IDX [N-1:0] complete_tags;
    [N-1:0] cdb_en;
    PHYS_REG_IDX [N-1:0] cdb_broadcast;

    task set_complete(
        int i,
        PHYS_REG_IDX tag
    )

    endtask

    task clear_complete(
        int i
    )

    endtask

endmodule