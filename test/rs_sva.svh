`include "sys_defs.svh"

`ifndef RS_SVA_SVH
`define RS_SVA_SVH


module rs_sva #(parameter 
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

    // ==== dut lines for comparison
    input   logic           [NUM_FU_ALU-1:0]    fu_vld_alu_dut,
    input   logic           [NUM_FU_MULT-1:0]   fu_vld_mult_dut,
    input   logic           [NUM_FU_STORE-1:0]  fu_vld_store_dut,
    input   logic           [NUM_FU_LOAD-1:0]   fu_vld_load_dut,
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
            $display("Entry [%0d]: busy=%b, issued=%b, t=%0d, t1=%0d, t2=%0d, t1_rdy=%b, t2_rdy=%b, fu=%s(%0d)",
                i, 
                entries[i].busy, 
                entries[i].issued, 
                entries[i].dat.t, 
                entries[i].dat.t1, 
                entries[i].dat.t2, 
                entries[i].dat.t1_rdy, 
                entries[i].dat.t2_rdy, 
                
                entries[i].busy ? fu_name : "*",
                entries[i].dat.fu_idx
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
    RS_ENTRY [RS_SZ-1:0] entries, entries_n;
    int num_free_fus    [FU_IDX_NUM];
    int num_issue_fus   [FU_IDX_NUM];
    int cdb_tags [int];

    logic [RS_SZ-1:0] busy_sva;
    logic [RS_SZ-1:0] busy_dut;
    logic [RS_SZ-1:0] issd_sva;
    logic [FU_IDX_NUM-1:0][RS_SZ-1:0] issd_sva_by_fu;
    logic [FU_IDX_NUM-1:0][RS_SZ-1:0] issd_dut_by_fu;
    generate
    for (genvar i = 0; i < RS_SZ; i++) begin : gen_vecs
        assign busy_sva[i] = entries[i].busy;
        assign busy_dut[i] = entries_dut[i].busy;

        assign issd_sva[i] = entries[i].issued;
    end
    endgenerate
    always_comb begin
        issd_sva_by_fu = '0;
        issd_dut_by_fu = '0;
        foreach(issd_sva_by_fu[fu, rs]) begin
            issd_sva_by_fu[fu][rs] |= (entries[rs].issued && entries[rs].dat.fu_idx == fu);
            issd_dut_by_fu[fu][rs] |= (entries_dut[rs].issued && entries_dut[rs].dat.fu_idx == fu);
        end
    end
    int rs_scnt_sva;

    always begin
        entries_n = entries;

        // clear (insn going to ex)
        for (int rs = 0; rs < RS_SZ; ++rs) begin
            if (entries_n[rs].issued) begin
                entries_n[rs] = '0;
            end
        end

        // ready insns (cdb)
        for (int rs = 0; rs < RS_SZ; ++rs) begin
            for (int n = 0; n < N; ++n) begin
                if (c_en[n] && entries_n[rs].dat.t1 == c_ts[n]) begin
                    entries_n[rs].dat.t1_rdy = 1;
                end

                if (c_en[n] && entries_n[rs].dat.t2 == c_ts[n]) begin
                    entries_n[rs].dat.t2_rdy = 1;
                end
            end
        end

        // issue
        num_free_fus[FU_ALU] = $countones(fu_rdy_alu);
        num_free_fus[FU_MULT] = $countones(fu_rdy_mult);
        num_free_fus[FU_STORE] = $countones(fu_rdy_store);
        num_free_fus[FU_LOAD] = $countones(fu_rdy_load);
        num_issue_fus[FU_ALU]   = 0;
        num_issue_fus[FU_MULT]  = 0;
        num_issue_fus[FU_STORE] = 0;
        num_issue_fus[FU_LOAD]  = 0;

        for (int rs = 0, int fu = 0; rs < RS_SZ; ++rs) begin
            fu = entries_n[rs].dat.fu_idx;
            if (entries_n[rs].dat.t1_rdy 
                && entries_n[rs].dat.t2_rdy
                && num_free_fus[fu] > 0
            ) begin
                num_free_fus[fu] -= 1;
                entries_n[rs].issued = 1;
                num_issue_fus[fu] += 1;
            end
        end

        // dispatch
        for (int n = 0, int rs = 0; n < N; ++n) begin
            if (!d_vld[n])
                continue;
            
            for (; rs < RS_SZ; ++rs) begin
                if (entries_n[rs].busy)
                    continue;
                entries_n[rs].busy   = 1;
                entries_n[rs].issued = 0;
                entries_n[rs].dat    = d_dat[n];
                break;
            end
        end
        assign rs_scnt_sva = $min($countones(~busy_sva | issd_sva), N);

        @(negedge clock);
        if (DEBUG) begin
            marker();
            print_entries(entries_dut);
        end
        // $display("<><><><><>");
        // print_entries(entries);
        // $display("FU_ALU: num_issue_fus[%0d] = %0d, $countones(fu_vld_alu_dut) = %0d", 
        //     FU_ALU, num_issue_fus[FU_ALU], $countones(fu_vld_alu_dut));
        // $display("FU_MULT: num_issue_fus[%0d] = %0d, $countones(fu_vld_mult_dut) = %0d", 
        //     FU_MULT, num_issue_fus[FU_MULT], $countones(fu_vld_mult_dut));
        // $display("FU_LOAD: num_issue_fus[%0d] = %0d, $countones(fu_vld_load_dut) = %0d", 
        //     FU_LOAD, num_issue_fus[FU_LOAD], $countones(fu_vld_load_dut));
        // $display("FU_STORE: num_issue_fus[%0d] = %0d, $countones(fu_vld_store_dut) = %0d", 
        //     FU_STORE, num_issue_fus[FU_STORE], $countones(fu_vld_store_dut));
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            entries <= '0;
        end else begin
            entries <= entries_n;
        end
    end


    clocking cb @(posedge clock);
        property same_num_busy;
            disable iff (reset || flush)
            $countones(busy_sva) == $countones(busy_dut);
        endproperty

        property same_rs_scnt;
            disable iff (reset || flush)
            rs_scnt == rs_scnt_sva;
        endproperty

        property issue_cnts;
            disable iff (reset || flush)
            /*TODO*/
            (num_issue_fus[FU_ALU] == $countones(fu_vld_alu_dut))
                && (num_issue_fus[FU_MULT] == $countones(fu_vld_mult_dut))
                && (num_issue_fus[FU_LOAD] == $countones(fu_vld_load_dut))
                && (num_issue_fus[FU_STORE] == $countones(fu_vld_store_dut));
            // 1;
        endproperty

        property issd_cnts;
            disable iff (reset || flush)
            /*TODO*/
            $countones(issd_dut_by_fu[FU_ALU]) == $countones(issd_sva_by_fu[FU_ALU])
            && $countones(issd_dut_by_fu[FU_MULT]) == $countones(issd_sva_by_fu[FU_MULT])
            && $countones(issd_dut_by_fu[FU_LOAD]) == $countones(issd_sva_by_fu[FU_LOAD])
            && $countones(issd_dut_by_fu[FU_STORE]) == $countones(issd_sva_by_fu[FU_STORE]);
        endproperty
    endclocking

    task exit_on_error(input string msg);
        begin
            // print_failure();
            $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
            $display("\033[31mError: %0s\033[0m\n\n", msg);
            print_entries(entries);
            print_entries(entries_dut);
            $display("FU_ALU: num_issue_fus[%0d] = %0d, $countones(fu_vld_alu_dut) = %0d", 
                FU_ALU, num_issue_fus[FU_ALU], $countones(fu_vld_alu_dut));
            $display("FU_MULT: num_issue_fus[%0d] = %0d, $countones(fu_vld_mult_dut) = %0d", 
                FU_MULT, num_issue_fus[FU_MULT], $countones(fu_vld_mult_dut));
            $display("FU_LOAD: num_issue_fus[%0d] = %0d, $countones(fu_vld_load_dut) = %0d", 
                FU_LOAD, num_issue_fus[FU_LOAD], $countones(fu_vld_load_dut));
            $display("FU_STORE: num_issue_fus[%0d] = %0d, $countones(fu_vld_store_dut) = %0d", 
                FU_STORE, num_issue_fus[FU_STORE], $countones(fu_vld_store_dut));

            $finish;
        end
    endtask


    Same_Num_Busy:  assert property(cb.same_num_busy)
        else exit_on_error ("diff num busy");
    Same_Rs_Scnt:  assert property(cb.same_rs_scnt)
        else exit_on_error ("diff rs scnt");
    Issue_Cnts:  assert property(cb.issue_cnts)
        else exit_on_error ("diff issue cnts");
    Issd_Cnts:  assert property(cb.issd_cnts)
        else exit_on_error ("diff issued cnts");

endmodule


`endif // RS_SVA_SVH