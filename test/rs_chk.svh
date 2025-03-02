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

    struct packed {
        logic           [N-1:0] d_vld;     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
        ID_RESULT       [N-1:0] d_dat;
        // issue
        logic           [NUM_FU_ALU-1:0]    fu_rdy_alu;
        logic           [NUM_FU_MULT-1:0]   fu_rdy_mult;
        logic           [NUM_FU_STORE-1:0]  fu_rdy_store;
        logic           [NUM_FU_LOAD-1:0]   fu_rdy_load;
        // complete
        logic           [N-1:0] c_en;
        PHYS_REG_IDX    [N-1:0] c_ts;
    } ins_pre, ins_cur; 

    struct packed {
        logic       [$clog2(N):0]       rs_scnt;
        
        logic       [NUM_FU_ALU-1:0]    fu_vld_alu;
        logic       [NUM_FU_MULT-1:0]   fu_vld_mult;
        logic       [NUM_FU_STORE-1:0]  fu_vld_store;
        logic       [NUM_FU_LOAD-1:0]   fu_vld_load;
        ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu;
        ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult;
        ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store;
        ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load;
    } outs_pre, outs_cur; 

    // This syntax is so fucking gorgeous btw.
    assign ins_cur = '{
        d_vld:d_vld,
        d_dat:d_dat,
        fu_rdy_alu:fu_rdy_alu,
        fu_rdy_mult:fu_rdy_mult,
        fu_rdy_load:fu_rdy_load,
        fu_rdy_store:fu_rdy_store,
        c_en:c_en,
        c_ts:c_ts
    };

    assign outs_cur = '{
        rs_scnt:rs_scnt,
        fu_vld_alu:fu_vld_alu_dut,
        fu_vld_mult:fu_vld_mult_dut,
        fu_vld_load:fu_vld_load_dut,
        fu_vld_store:fu_vld_store_dut,
        fu_dat_alu:fu_dat_alu_dut,
        fu_dat_mult:fu_dat_mult_dut,
        fu_dat_load:fu_dat_load_dut,
        fu_dat_store:fu_dat_store_dut
    };
    
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

    int rs_scnt_sva;
    RS_ENTRY [RS_SZ-1:0] 
        entries_pre,      // prev value (updated to entries_cur on posedge)
        entries_mut,      // scratchpad (entries_pre with some modifications)
        entries_cur;      // next value (set by rs module)
    assign entries_cur = entries_dut;
    int id2idx_pre[int],
        id2idx_mut[int],
        id2idx_cur[int];

    // misc control

    // clear correctness
    logic clear_correct;

    // ready correctness
    logic ready_correct;
    logic rdy_mut[int];
    logic readied_pre[int]; // was readied last cycle

    // issue correctness
    logic issue_cnt_correct;
    logic issue_asg_correct;
    logic issue_dat_correct;
    // logic issd_mut[int], issd_cur[int];

    logic [RS_SZ-1:0] issd_cur;
    logic [FU_IDX_NUM-1:0][RS_SZ-1:0] issd_by_fu_cur;
    logic [RS_SZ-1:0] can_issue_mut;
    logic [FU_IDX_NUM-1:0][RS_SZ-1:0] can_issue_by_fu_mut;

    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin
        marker();
        $display("entries_pre");
        print_entries(entries_pre);
        $display("entries_cur");
        print_entries(entries_cur);

        // initialization
        id2idx_pre.delete();
        foreach(entries_pre[rs]) begin
            if (entries_pre[rs].busy)
                id2idx_pre[entries_pre[rs].dat.id] = rs;
        end
        id2idx_cur.delete();
        foreach(entries_cur[rs]) begin
            if (entries_cur[rs].busy)
                id2idx_cur[entries_cur[rs].dat.id] = rs;
        end

        // marker();
        // $display("entries_pre");
        // print_entries(entries_pre);
        // $display("entries_cur");
        // print_entries(entries_cur);

        // check clear correctness (insn going to ex)
        clear_correct = 1;
        for (int rs = 0, int id = 0; rs < RS_SZ; ++rs) begin
            if (!entries_pre[rs].issued)
                continue;
            id = entries_pre[rs].dat.id;
            clear_correct &= (!id2idx_cur.exists(id));

            entries_mut[rs] = '0;
        end 

        // check ready correctness 
        ready_correct = 1;
        for (int rs = 0, PHYS_REG_IDX t1 = 0, PHYS_REG_IDX t2 = 0; rs < RS_SZ; ++rs) begin
            if (!entries_cur[rs].busy)
                continue;
            t1 = entries_cur[rs].dat.t1;
            t2 = entries_cur[rs].dat.t2;

            foreach (ins_pre.c_en[i]) begin
                if (!ins_pre.c_en[i])
                    continue;
                ready_correct &= (ins_pre.c_ts[i] == t1 ? entries_cur[rs].dat.t1_rdy : 1);
                ready_correct &= (ins_pre.c_ts[i] == t2 ? entries_cur[rs].dat.t2_rdy : 1);
            end
        end

        // update ready in scratchpad
        entries_mut = entries_pre;
        for (int rs = 0, PHYS_REG_IDX t1 = 0, PHYS_REG_IDX t2 = 0; rs < RS_SZ; ++rs) begin
            t1 = entries_pre[rs].dat.t1;
            t2 = entries_pre[rs].dat.t2;
            foreach (ins_pre.c_en[i]) begin
                if (!ins_pre.c_en[i])
                    continue;
                entries_mut[rs].dat.t1_rdy |= (ins_pre.c_ts[i] == t1);
                entries_mut[rs].dat.t2_rdy |= (ins_pre.c_ts[i] == t2);
            end
        end

        // check issue correctness
        issd_cur        = '0;
        issd_by_fu_cur  = '0;
        for (int rs = 0, FU_IDX fu = 0; rs < RS_SZ; ++rs) begin
            issd_cur[rs] = entries_cur[rs].busy && entries_cur[rs].issued;
            // $display("duck[%0d]: %b", rs, issd_cur[rs]);
            fu = entries_cur[rs].dat.fu_idx;
            issd_by_fu_cur[fu][rs] = issd_cur[rs];
            // $display("golo[%0d]: fu=%0d %b", rs, fu, issd_by_fu_cur[fu][rs]);
        end

        can_issue_mut       = '0;
        can_issue_by_fu_mut = '0;
        for (int rs = 0, FU_IDX fu = 0; rs < RS_SZ; ++rs) begin
            can_issue_mut[rs] = entries_mut[rs].busy
                && !entries_mut[rs].issued
                && (entries_mut[rs].dat.t1_rdy)
                && (entries_mut[rs].dat.t2_rdy);
            fu = entries_mut[rs].dat.fu_idx;
            can_issue_by_fu_mut[fu][rs] = can_issue_mut[rs];
        end

        issue_cnt_correct = 1;
        for (int fu = 0, int rdy_num = 0; fu < FU_IDX_NUM; ++fu) begin
            case (fu) 
            FU_ALU:     rdy_num = $countones(ins_pre.fu_rdy_alu);
            FU_MULT:    rdy_num = $countones(ins_pre.fu_rdy_mult);
            FU_LOAD:    rdy_num = $countones(ins_pre.fu_rdy_load);
            FU_STORE:   rdy_num = $countones(ins_pre.fu_rdy_store);
            endcase
            // $display("fu=%0d: issd:      %0b", fu, issd_by_fu_cur[fu]);
            // $display("fu=%0d: can_issue: %0b", fu, can_issue_by_fu_mut[fu]);
            // $display("fu=%0d: rdy_num:   %0d", fu, rdy_num);
            issue_cnt_correct &= 
                $countones(issd_by_fu_cur[fu])
                == $min($countones(can_issue_by_fu_mut[fu]), rdy_num);
        end

        issue_asg_correct = 1; // is data assigned to a read fu?
        issue_dat_correct = 1;
        for (int i = 0, int id = 0, int rs = 0; i < NUM_FU_ALU; ++i) begin
            if (!outs_pre.fu_vld_alu[i])
                continue;
            issue_asg_correct &= ins_pre.fu_rdy_alu[i];
            id = outs_pre.fu_dat_alu[i].id;
            if (!id2idx_pre.exists(id)) begin
                $display("WHAT THE FUCK?");
                $finish;
            end
            rs = id2idx_pre[id];
            issue_dat_correct &= (outs_pre.fu_dat_alu[i] == entries_pre[rs].dat);
        end
        for (int i = 0, int id = 0, int rs = 0; i < NUM_FU_MULT; ++i) begin
            if (!outs_pre.fu_vld_mult[i])
                continue;
            issue_asg_correct &= ins_pre.fu_rdy_mult[i];
            id = outs_pre.fu_dat_mult[i].id;
            rs = id2idx_pre[id];
            issue_dat_correct &= (outs_pre.fu_dat_mult[i] == entries_pre[rs].dat);
        end
        for (int i = 0, int id = 0, int rs = 0; i < NUM_FU_LOAD; ++i) begin
            if (!outs_pre.fu_vld_load[i])
                continue;
            issue_asg_correct &= ins_pre.fu_rdy_load[i];
            id = outs_pre.fu_dat_load[i].id;
            rs = id2idx_pre[id];
            issue_dat_correct &= (outs_pre.fu_dat_load[i] == entries_pre[rs].dat);
        end
        for (int i = 0, int id = 0, int rs = 0; i < NUM_FU_STORE; ++i) begin
            if (!outs_pre.fu_vld_store[i])
                continue;
            issue_asg_correct &= ins_pre.fu_rdy_store[i];
            id = outs_pre.fu_dat_store[i].id;
            rs = id2idx_pre[id];
            issue_dat_correct &= (outs_pre.fu_dat_store[i] == entries_pre[rs].dat);
        end
        
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
        property ex_clear;
            disable iff (reset || flush)
            clear_correct;
        endproperty
        property c_rdy;
            disable iff (reset || flush)
            ready_correct;
        endproperty

        property issue_cnt;
            disable iff (reset || flush)
            issue_cnt_correct;
        endproperty

        property issue_asg;
            disable iff (reset || flush)
            issue_asg_correct;
        endproperty

        property issue_dat;
            disable iff (reset || flush)
            issue_dat_correct;
        endproperty
    endclocking

    Ex_Clear: assert property(cb.ex_clear)
        else exit_on_error ("did not clear");
    C_Rdy: assert property(cb.c_rdy)
        else exit_on_error ("did not ready");
    Issue_Cnt: assert property(cb.issue_cnt)
        else exit_on_error ("issue cnt wrong");
    Issue_Asg: assert property(cb.issue_asg)
        else exit_on_error ("issue assignment wrong");
    Issue_Dat: assert property(cb.issue_dat)
        else exit_on_error ("issue dat wrong");


endmodule


`endif // RS_CHK_SVH