`include "sys_defs.svh"

`ifndef MT_SVA_SVH
`define MT_SVA_SVH

module mt_sva #(parameter 
    N=`N
) (
    input   clock, reset,
    // retire ??

    // complete
    input   execute2complete    c_in,

    // issue ??

    // dispatch
    input   dispatch2map_table  d_in,
    input   map_table2dispatch  d_out_dut
);
    localparam DEBUG = 1;

    function void marker();
        static int i = 0;
        $display("%d !!!!:", i++);
    endfunction

    function get_fu_name(input FU_IDX fu_idx, output string name);
        case (fu_idx)
            FU_ALU:     name = "ALU";
            FU_MULT:    name = "MULT";
            FU_LOAD:    name = "LOAD";
            FU_STORE:   name = "STORE";
            default:    name = "Unknown FU";
        endcase
    endfunction

    function print_entries(input RS_ENTRY [RS_SZ-1:0] entries);
        for (int i = 0; i < RS_SZ; ++i) begin
            string fu_name;
            get_fu_name(entries[i].dat.fu_idx, fu_name);

            if (!entries[i].busy) begin
                $display("Entry [%0d]:", i);
                continue;
            end

            $display("Entry [%0d]: id=%0d, busy=%b, issued=%b, t=%0d, t1=%0d, t2=%0d, t1_rdy=%b, t2_rdy=%b, fu=%s(%0d)",
                i, 
                entries[i].dat.id, 
                entries[i].busy, 
                entries[i].issued, 
                entries[i].dat.t, 
                entries[i].dat.t1, 
                entries[i].dat.t2, 
                entries[i].dat.t1_rdy, 
                entries[i].dat.t2_rdy, 
                
                entries[i].busy ? fu_name : "*",
                entries[i].dat.fu_idx,
                // entries[i].dat.PC, 
                // entries[i].dat.NPC, 
                // entries[i].dat.alu_func, 
                // entries[i].dat.mult, 
                // entries[i].dat.rd_mem, 
                // entries[i].dat.wr_mem, 
                // entries[i].dat.cond_branch, 
                // entries[i].dat.uncond_branch, 
                // entries[i].dat.halt, 
                // entries[i].dat.illegal, 
                // entries[i].dat.csr_op
            );
        end
    endfunction

    struct packed {
        execute2complete    c_in;
        dispatch2map_table  d_in;
    } ins_pre, ins_cur; 

    struct packed {
        map_table2dispatch  d_out;
    } outs_pre, outs_cur; 

    // This syntax is so fucking gorgeous btw.
    assign ins_cur = '{
        c_in:c_in,
        d_in:d_in
    };

    assign outs_cur = '{
        d_out:d_out_dut
    };
    

    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin

        @(posedge clock);

        @(negedge clock);




    end end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            entries_pre <= '0;
            ins_pre     <= '0;
            outs_pre    <= '0;
        end else begin
            entries_pre <= entries_cur;
            ins_pre     <= ins_cur;
            outs_pre    <= outs_cur;
        end
    end


    task exit_on_error(input string msg);
        begin
            // print_failure();
            $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
            $display("\033[31mError: %0s\033[0m\n\n", msg);
            // foreach(id2idx[id]) $display("id2[%0d]: %0d", id, id2idx[id]);
            // foreach(id2idx_n[id]) $display("id2_n[%0d]: %0d", id, id2idx_n[id]);
            // $display("entries:");
            // print_entries(entries);
            // $display("entries_cur:");
            // print_entries(entries_cur);

            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        // property ex_clear;
        //     disable iff (reset || flush)
        //     clear_correct;
        // endproperty
    endclocking

    // Ex_Clear: assert property(cb.ex_clear)
    //     else exit_on_error ("did not clear");

endmodule
`endif // MT_SVA_SVH