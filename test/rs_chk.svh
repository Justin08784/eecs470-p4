`include "sys_defs.svh"

`ifndef RS_CHK_SVH
`define RS_CHK_SVH

module rs_chk #(parameter 
    N=`N,
    RS_SZ=`RS_SZ,
    FU_IDX_NUM=`FU_IDX_NUM,
    NUM_FU_ALU=`NUM_FU_ALU,
    NUM_FU_MULT=`NUM_FU_MULT,
    NUM_FU_LOAD=`NUM_FU_LOAD,
    NUM_FU_STORE=`NUM_FU_STORE
) (
    // ==== input lines so we can do our own parallel computation
    input clock,
    input reset,
    input flush,
    // dispatch
    input   logic           [$clog2(N):0] rs_scnt, // to dispatcher
    input   logic           [N-1:0] d_vld,     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    input   ID_RESULT       [N-1:0] d_dat,
    // issue
    input   logic           [NUM_FU_ALU-1:0]    fu_rdy_alu,
    input   logic           [NUM_FU_MULT-1:0]   fu_rdy_mult,
    input   logic           [NUM_FU_STORE-1:0]  fu_rdy_store,
    input   logic           [NUM_FU_LOAD-1:0]   fu_rdy_load,
    // complete
    input   logic           [N-1:0] c_en,
    input   PHYS_REG_IDX    [N-1:0] c_ts,

    // delicious spaghetti for print debugging
    // input   logic           [RS_SZ-1:0]   to_t1_rdy_dut,
    // input   logic           [RS_SZ-1:0]   to_t2_rdy_dut,
    // input   logic           [RS_SZ-1:0]   can_issue_dut,
    // input   logic           [FU_IDX_NUM-1:0][RS_SZ-1:0]   can_issues_dut,

    // ==== dut lines for comparison
    input   logic           [NUM_FU_ALU-1:0]    fu_vld_alu_dut,
    input   logic           [NUM_FU_MULT-1:0]   fu_vld_mult_dut,
    input   logic           [NUM_FU_STORE-1:0]  fu_vld_store_dut,
    input   logic           [NUM_FU_LOAD-1:0]   fu_vld_load_dut,
    input   ID_RESULT       [NUM_FU_ALU-1:0]    fu_dat_alu_dut,
    input   ID_RESULT       [NUM_FU_MULT-1:0]   fu_dat_mult_dut,
    input   ID_RESULT       [NUM_FU_STORE-1:0]  fu_dat_store_dut,
    input   ID_RESULT       [NUM_FU_LOAD-1:0]   fu_dat_load_dut,
    input   RS_ENTRY        [RS_SZ-1:0]         entries_dut
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
    logic               [NUM_FU_ALU-1:0]    fu_vld_alu;
    logic               [NUM_FU_MULT-1:0]   fu_vld_mult;
    logic               [NUM_FU_STORE-1:0]  fu_vld_store;
    logic               [NUM_FU_LOAD-1:0]   fu_vld_load;
    ID_RESULT           [NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT           [NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT           [NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT           [NUM_FU_LOAD-1:0]   fu_dat_load;
    int num_free_fus    [FU_IDX_NUM];
    int num_issue_fus   [FU_IDX_NUM];
    int cdb_tags [int];

    logic [RS_SZ-1:0] busy_sva;
    logic [RS_SZ-1:0] issd_sva;
    generate
    for (genvar i = 0; i < RS_SZ; i++) begin : gen_vecs
        assign busy_sva[i] = entries[i].busy;
        assign issd_sva[i] = entries[i].issued;
    end
    endgenerate
    
    int rs_scnt_sva;
    RS_ENTRY [RS_SZ-1:0] 
        entries,        // prev value (updated to entries_n on posedge)
        entries_mut,    // prev value with some mutations (hence "mut"); scratchpad for correctness calculations
        entries_n;      // next value (set by rs module)
    assign entries_n = entries_dut;
    int id2idx[int], id2idx_mut[int], id2idx_n[int];

    // misc control

    // clear correctness
    logic clear_correct;

    // ready correctness
    logic ready_correct;
    logic rdy_mut[int];
    logic last_cycle_rdy[int];

    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        while (!reset)
            @(negedge clock);
        @(negedge clock);   
    forever begin
        marker();
        $display("entries");
        print_entries(entries);
        $display("entries_n");
        print_entries(entries_n);
        id2idx_n.delete();
        foreach(entries_n[rs]) begin
            if (entries_n[rs].busy)
                id2idx_n[entries_n[rs].dat.id] = rs;
        end


        rdy_mut.delete();
        id2idx_mut.delete();
        foreach(id2idx[id])
            id2idx_mut[id] = id2idx[id];
        entries_mut = entries;


        // ready insns (cdb)
        foreach(last_cycle_rdy[t]) begin
            $display("fig[%0d]=%b", t, last_cycle_rdy[t]);
        end
        ready_correct = 1;
        for (int rs = 0, 
             PHYS_REG_IDX t1 = 0, PHYS_REG_IDX t2 = 0,
             logic t1_rdy = 0, logic t2_rdy = 0; rs < RS_SZ; ++rs) begin
            if (!entries[rs].busy)
                continue;

            // id = entries_mut[rs].dat.id;
            t1 = entries[rs].dat.t1;
            t2 = entries[rs].dat.t2;
            t1_rdy = entries[rs].dat.t1_rdy;
            t2_rdy = entries[rs].dat.t2_rdy;
            if (last_cycle_rdy.exists(t1)) begin
                $display("check t1: %0d %b %b", t1, t1_rdy, last_cycle_rdy[t1]);
                ready_correct &= (t1_rdy == last_cycle_rdy[t1]);
            end
            if (last_cycle_rdy.exists(t2)) begin
                $display("check t2: %0d %b %b", t2, t2_rdy, last_cycle_rdy[t2]);
                ready_correct &= (t2_rdy == last_cycle_rdy[t2]);
            end
        end 


        @(posedge clock);
        #0

        // correctness checks ABOVE

        // state updates BELOW


        // clear (insn going to ex)
        clear_correct = 1;
        for (int rs = 0, int id = 0; rs < RS_SZ; ++rs) begin
            if (!entries_mut[rs].issued)
                continue;
            id = entries_mut[rs].dat.id;
            clear_correct &= (!id2idx_n.exists(id));

            entries_mut[rs] = '0;
            id2idx_mut.delete(id);
        end 

        // ready insns (cdb)
        last_cycle_rdy.delete();
        #0
        for (int rs = 0, PHYS_REG_IDX t1 = 0, PHYS_REG_IDX t2 = 0; rs < RS_SZ; ++rs) begin
            if (!entries_mut[rs].busy)
                continue;

            // id = entries_mut[rs].dat.id;
            t1 = entries_mut[rs].dat.t1;
            t2 = entries_mut[rs].dat.t2;
            last_cycle_rdy[t1] = entries_mut[rs].dat.t1_rdy;
            last_cycle_rdy[t2] = entries_mut[rs].dat.t2_rdy;
        end 
        foreach (c_ts[i]) begin
            $display("cdb[%0d]= %0d", i, c_ts[i]);
            if (!c_en[i]) 
                continue;
            last_cycle_rdy[c_ts[i]] = 1;
        end
        foreach(last_cycle_rdy[t]) begin
            $display("last_cycle_rdy[%0d]=%b", t, last_cycle_rdy[t]);
        end
        @(negedge clock);




    end end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            entries <= '0;
            id2idx.delete();
        end else begin
            entries <= entries_n;
            id2idx.delete();
            foreach (id2idx_n[id])
                id2idx[id] <= id2idx_n[id];
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
            // $display("entries_n:");
            // print_entries(entries_n);

            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        property ex_clear;
            disable iff (reset || flush)
            clear_correct;
        endproperty
        property c_rdy;
            disable iff (reset || flush)
            ready_correct;
        endproperty
    endclocking

    // Ex_Clear: assert property(cb.ex_clear)
    //     else exit_on_error ("did not clear");
    C_Rdy: assert property(cb.c_rdy)
        else exit_on_error ("did not ready");


endmodule


`endif // RS_CHK_SVH