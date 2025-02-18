

`include "sys_defs.svh"

typedef struct packed {
    logic busy;
    logic [2:0] op;
    logic [5:0] tag;
    logic [5:0] t1;
    logic t1_ready;
    logic [5:0] t2;
    logic t2_ready;
} RS_ENTRY;


module rs (
    input clock,
    input reset,
    input allocate_en,
    input [$bits(RS_ENTRY)-1:0] rd_allocate,
    input cdb_en,
    input cdb_tag,
    // output logic tag_en,
    // output  logic [5:0] tag,
    output logic free_en,
    output logic [$bits(RS_ENTRY)-1:0] wr_free,
    output logic [$bits(ID_EX_PACKET)-1:0] inst
);


RS_ENTRY [31:0] reservation_table;


endmodule