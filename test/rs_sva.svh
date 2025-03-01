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

            $display("Entry [%0d]: PC=%0x, busy=%b, issued=%b, t=%0d, t1=%0d, t2=%0d, t1_rdy=%b, t2_rdy=%b, fu=%s(%0d)",
                i, 
                entries[i].dat.PC, 
                entries[i].busy, 
                entries[i].issued, 
                entries[i].dat.t, 
                entries[i].dat.t1, 
                entries[i].dat.t2, 
                entries[i].dat.t1_rdy, 
                entries[i].dat.t2_rdy, 
                
                entries[i].busy ? fu_name : "*",
                entries[i].dat.fu_idx,
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
    logic [RS_SZ-1:0] issd_sva;
    generate
    for (genvar i = 0; i < RS_SZ; i++) begin : gen_vecs
        assign busy_sva[i] = entries[i].busy;
        assign issd_sva[i] = entries[i].issued;
    end
    endgenerate
    
    int rs_scnt_sva;
    // struct packed {
    //     int     idx; // idx of original element
    //     logic   busy;
    //     ADDR    PC;
    // }   entries_sva_sorter[RS_SZ],
    //     entries_dut_sorter[RS_SZ];
    logic   [RS_SZ-1:0] entries_eqs;
    RS_ENTRY entries_sva_sorted[RS_SZ], entries_dut_sorted[RS_SZ];

    `define MAX(a, b) ((a) > (b) ? (a) : (b))
    localparam MAX_NUM_FU = `MAX(NUM_FU_ALU, `MAX(NUM_FU_MULT, `MAX(NUM_FU_LOAD, NUM_FU_STORE)));
    // struct packed {
    //     int     idx; // idx of original element
    //     logic   vld;
    //     ADDR    PC;
    // }   fu_dat_sva_sorter[MAX_NUM_FU],
    //     fu_dat_dut_sorter[MAX_NUM_FU];
    logic   [NUM_FU_ALU-1:0]    fu_dat_alu_eqs;
    logic   [NUM_FU_MULT-1:0]   fu_dat_mult_eqs;
    logic   [NUM_FU_LOAD-1:0]   fu_dat_load_eqs;
    logic   [NUM_FU_STORE-1:0]  fu_dat_store_eqs;
    ID_RESULT [MAX_NUM_FU-1:0]  fu_dat_sva_sorted, fu_dat_dut_sorted;

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
        num_free_fus[FU_ALU]    = $countones(fu_rdy_alu);
        num_free_fus[FU_MULT]   = $countones(fu_rdy_mult);
        num_free_fus[FU_STORE]  = $countones(fu_rdy_store);
        num_free_fus[FU_LOAD]   = $countones(fu_rdy_load);

        for (int rs = 0, int fu = 0; rs < RS_SZ; ++rs) begin
            fu = entries_n[rs].dat.fu_idx;
            if (entries_n[rs].dat.t1_rdy 
                && entries_n[rs].dat.t2_rdy
                && num_free_fus[fu] > 0
            ) begin
                num_free_fus[fu] -= 1;
                entries_n[rs].issued = 1;
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


        // Sort-check entries: sort entries, entries_dut by ascending {busy, PC}
        // then do entrywise comparison. 

        // Version 1: Sort a copy of original arrays
        foreach(entries[i]) entries_sva_sorted[i] = entries[i];
        foreach(entries[i]) entries_dut_sorted[i] = entries_dut[i];
        entries_sva_sorted.sort() with ({item.busy, item.dat.PC});
        entries_dut_sorted.sort() with ({item.busy, item.dat.PC});
        foreach(entries[i]) entries_eqs[i] = entries_sva_sorted[i] == entries_dut_sorted[i];

        /* Version 2: Sort a sorter struct to index into original arrays */
        // for (int rs = 0; rs < RS_SZ; ++rs) begin
        //     entries_sva_sorter[rs].idx  = rs;
        //     entries_sva_sorter[rs].busy = entries[rs].busy;
        //     entries_sva_sorter[rs].PC   = entries[rs].dat.PC;

        //     entries_dut_sorter[rs].idx  = rs;
        //     entries_dut_sorter[rs].busy = entries_dut[rs].busy;
        //     entries_dut_sorter[rs].PC   = entries_dut[rs].dat.PC;
        // end
        // entries_sva_sorter.sort() with ({item.busy, item.PC});
        // entries_dut_sorter.sort() with ({item.busy, item.PC});
        // for (int rs = 0, RS_ENTRY l=0, RS_ENTRY r=0; rs < RS_SZ; ++rs) begin
        //     l = entries_dut[entries_dut_sorter[rs].idx];
        //     r = entries[entries_sva_sorter[rs].idx];
        //     entries_eqs[rs] = l == r;
        // end

        // Sort-check fu_dats: sort fu_dats by ascending {busy, PC}
        // then do entrywise comparison. 
        // foreach(fu_dat_alu_eqs[i]) fu_dat_sva_sorted[i] = entries[i];
        // foreach(fu_dat_alu_eqs[i]) fu_dat_dut_sorted[i] = entries_dut[i];
        // entries_sva_sorted.sort() with ({item.busy, item.dat.PC});
        // entries_dut_sorted.sort() with ({item.busy, item.dat.PC});
        // foreach(fu_dat_alu_eqs[i]) entries_eqs[i] = entries_sva_sorted[i] == entries_dut_sorted[i];

        @(negedge clock);
        // if (DEBUG) begin
        marker();
        $write("cdb={");
        for (int i = 0; i < N; ++i) begin
            $write("%0d:%0b, ", i, c_en[i] ? c_ts[i] : 'x);
        end
        $write("}\n");
        $display("fu_rdy={FU_ALU: %b, FU_MULT: %b, FU_LOAD: %b, STORE: %b}",
            fu_rdy_alu,
            fu_rdy_mult,
            fu_rdy_load,
            fu_rdy_store
        );
        $display("dut:");
        print_entries(entries_dut);
        // end
        $display("sva:");
        print_entries(entries);
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
            // $countones(busy_sva) == $countones(busy_dut);
            1;
        endproperty

        property same_rs_scnt;
            disable iff (reset || flush)
            rs_scnt == rs_scnt_sva;
        endproperty

        property issue_cnts;
            disable iff (reset || flush)
            /*TODO*/
            // (num_issue_fus[FU_ALU] == $countones(fu_vld_alu_dut))
            //     && (num_issue_fus[FU_MULT] == $countones(fu_vld_mult_dut))
            //     && (num_issue_fus[FU_LOAD] == $countones(fu_vld_load_dut))
            //     && (num_issue_fus[FU_STORE] == $countones(fu_vld_store_dut));
            1;
        endproperty

        property issd_cnts;
            disable iff (reset || flush)
            /*TODO*/
            // $countones(issd_dut_by_fu[FU_ALU]) == $countones(issd_sva_by_fu[FU_ALU])
            // && $countones(issd_dut_by_fu[FU_MULT]) == $countones(issd_sva_by_fu[FU_MULT])
            // && $countones(issd_dut_by_fu[FU_LOAD]) == $countones(issd_sva_by_fu[FU_LOAD])
            // && $countones(issd_dut_by_fu[FU_STORE]) == $countones(issd_sva_by_fu[FU_STORE]);
            1;
        endproperty

        property entries_eq;
            disable iff (reset || flush)
            /*TODO*/
            &entries_eqs;
        endproperty
    endclocking

    task exit_on_error(input string msg);
        begin
            // print_failure();
            $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
            $display("\033[31mError: %0s\033[0m\n\n", msg);
            print_entries(entries);
            print_entries(entries_dut);

            $finish;
        end
    endtask


    // Same_Num_Busy:  assert property(cb.same_num_busy)
    //     else exit_on_error ("diff num busy");
    Same_Rs_Scnt:  assert property(cb.same_rs_scnt)
        else exit_on_error ("diff rs scnt");
    // Issue_Cnts:  assert property(cb.issue_cnts)
    //     else exit_on_error ("diff issue cnts");
    // Issd_Cnts:  assert property(cb.issd_cnts)
    //     else exit_on_error ("diff issued cnts");
    Entries_Eq:  assert property(cb.entries_eq)
        else exit_on_error ("diff entries");

endmodule


`endif // RS_SVA_SVH