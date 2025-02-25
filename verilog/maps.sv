`include "sys_defs.svh"


module map_table(
    input clock,
    input reset,

    input new_map,

    output map_table
);

always_ff @(posedge clock) begin
    if (reset) begin
        map_table <= default_map_table();
    end
    else begin
        map_table <= new_map;
    end    
end

endmodule



module arch_map(

);


endmodule



module free_list(

);



endmodule


task default_map_table;

    output default_table;

    begin

    end
endtask