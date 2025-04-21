`include "sys_defs.svh"

module btb(
    input  logic        clock, reset,
    input  fetch2btb  fetch_in,
    output btb2fetch   fetch_out         
);

logic [`BTB_ENTRIES-1:0] [`BTB_TAG_WIDTH-1:0] tag_array;
logic [`BTB_ENTRIES-1:0]  [`BTB_TARGET_WIDTH-1:0] target_array;

logic [`BTB_ENTRIES-1:0] valid_array;

logic [7:0] index;
logic [`BTB_TAG_WIDTH-1:0] tag;


always_comb begin
    fetch_out.hit = 2'b00;
    for(int i = 0; i < `N; i++) begin

        index = fetch_in.PC[i][9:2];
        tag = fetch_in.PC[i][31:10];

        if(valid_array[index] && tag_array[index] == tag) begin
            fetch_out.hit[i] = 1'b1;
            fetch_out.target[i] = target_array[index];
        end else begin
            fetch_out.hit[i] = 1'b0;
            fetch_out.target[i] = '0;
        end
    end
end


logic [7:0] reg_index;

always_ff @(posedge clock) begin 
    if(reset) begin
        for(int i = 0; i < `BTB_ENTRIES; i++) begin
            valid_array[i] <= 1'b0;
            tag_array[i] <= '0;
            target_array[i] <= '0;
        end
    end else begin
        for(int i = 0; i < `N; i++) begin
            if(fetch_in.is_taken[i]) begin
                reg_index = fetch_in.correct_PC[i][9:2];
                tag_array[reg_index] <= fetch_in.correct_PC[i][31:10];
                target_array[reg_index] <= fetch_in.target[0]; //[13:2]
                valid_array[reg_index] <= 1'b1;
            end
        end
    end
end


endmodule