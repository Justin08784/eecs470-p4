`include "sys_defs.svh"

`ifndef MT_SVA_SVH
`define MT_SVA_SVH

module mt_sva #(parameter 
    N=`N,
    localparam NUM_ARCH_REG=32
) (
    input   clock, reset,
    // retire ??
    input struct packed {
        PHYS_REG_IDX t;
        logic cpl;
    } [NUM_ARCH_REG-1:0]        entries_dut,

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

    // function print_entries(input RS_ENTRY [RS_SZ-1:0] entries);
    //     for (int i = 0; i < RS_SZ; ++i) begin
    //         string fu_name;
    //         get_fu_name(entries[i].dat.fu_idx, fu_name);

    //         if (!entries[i].busy) begin
    //             $display("Entry [%0d]:", i);
    //             continue;
    //         end

    //         $display("Entry [%0d]: id=%0d, busy=%b, issued=%b, t=%0d, t1=%0d, t2=%0d, t1_rdy=%b, t2_rdy=%b, fu=%s(%0d)",
    //             i, 
    //             entries[i].dat.id, 
    //             entries[i].busy, 
    //             entries[i].issued, 
    //             entries[i].dat.t, 
    //             entries[i].dat.t1, 
    //             entries[i].dat.t2, 
    //             entries[i].dat.t1_rdy, 
    //             entries[i].dat.t2_rdy, 
                
    //             entries[i].busy ? fu_name : "*",
    //             entries[i].dat.fu_idx,
    //             // entries[i].dat.PC, 
    //             // entries[i].dat.NPC, 
    //             // entries[i].dat.alu_func, 
    //             // entries[i].dat.mult, 
    //             // entries[i].dat.rd_mem, 
    //             // entries[i].dat.wr_mem, 
    //             // entries[i].dat.cond_branch, 
    //             // entries[i].dat.uncond_branch, 
    //             // entries[i].dat.halt, 
    //             // entries[i].dat.illegal, 
    //             // entries[i].dat.csr_op
    //         );
    //     end
    // endfunction

    struct packed {
        execute2complete    c_in;
        dispatch2map_table  d_in;
    } ins_pre, ins_cur; 
    struct packed {
        map_table2dispatch  d_out;
    } outs_pre, outs_cur; 
    struct packed {
        PHYS_REG_IDX t;
        logic cpl;
    } [NUM_ARCH_REG-1:0]
        entries_pre,
        entries_mut,
        entries_cur;

    // This syntax is so fucking gorgeous btw.
    assign ins_cur = '{
        c_in:c_in,
        d_in:d_in
    };
    assign outs_cur = '{
        d_out:d_out_dut
    };
    assign entries_cur = entries_dut;
    

    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin
        entries_mut = entries_pre;
        $display("sdlkajf: %b", entries_cur);

        @(posedge clock);
        @(negedge clock);
    end end

    always_ff @(posedge clock) begin
        if (reset) begin
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

    function automatic logic check_sources(
        input int i,            // which dispatch slot

        input REG_IDX src,
        input PHYS_REG_IDX src_tag,
        input logic src_cpl
    );
        PHYS_REG_IDX true_src_tag;
        PHYS_REG_IDX true_src_cpl;
        logic from_state;

        from_state = `TRUE;
        for (int j = i - 1; j >= 0; --j) begin
            if (ins_cur.d_in.dsts[j] == src) begin
                from_state = `FALSE;
                true_src_tag = ins_cur.d_in.ts[j];
                true_src_cpl = src == `ZERO_REG;
                break;
            end
        end
        if (from_state) begin
            true_src_tag = entries_pre[src].t;
            true_src_cpl = entries_pre[src].cpl;
        end

        return (src_tag == true_src_tag) && (src_cpl == true_src_cpl);
    endfunction


    clocking cb @(posedge clock);
        property zero_reg_invariant;
            disable iff (reset)
            (entries_cur[`ZERO_REG].t == '0) && entries_cur[`ZERO_REG].cpl;
        endproperty

        property correct_deps(i);
            disable iff (reset)
            (ins_cur.d_in.en_cnt > i) |->  (
            check_sources(
                i,
                ins_cur.d_in.src1s[i],
                outs_cur.d_out.t1s[i],
                outs_cur.d_out.cpl1s[i]
            ) && 
            check_sources(
                i,
                ins_cur.d_in.src2s[i],
                outs_cur.d_out.t2s[i],
                outs_cur.d_out.cpl2s[i]
            ));
        endproperty
        // property ex_clear;
        //     disable iff (reset || flush)
        //     clear_correct;
        // endproperty
    endclocking

    Zero_Reg_Invariant: assert property(cb.zero_reg_invariant)
        else exit_on_error ("zero reg changed");
    generate
        for (genvar i = 0; i < `N; ++i) begin : gen_correct_deps
            assert property(cb.correct_deps(i))
                else exit_on_error("shit");
        end
    endgenerate

endmodule
`endif // MT_SVA_SVH