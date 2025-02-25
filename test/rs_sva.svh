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
    input clock,
    input reset,
    input flush,
    input RS_ENTRY [RS_SZ-1:0] entries_dbg,
    input logic [N-1:0][RS_SZ-1:0] free_gnt_bus_dbg,
    input [N-1:0][RS_SZ-1:0] d_gnt_bus_dbg,

    // dispatch
    input   logic           [$clog2(N):0] rs_scnt, // to dispatcher
    input   logic           [N-1:0] d_vld,     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    input   ID_RESULT       [N-1:0] d_dat,

    // issue
    input   logic       [NUM_FU_ALU-1:0]    fu_rdy_alu,
    input   logic       [NUM_FU_MULT-1:0]   fu_rdy_mult,
    input   logic       [NUM_FU_STORE-1:0]  fu_rdy_store,
    input   logic       [NUM_FU_LOAD-1:0]   fu_rdy_load,

    input   logic       [NUM_FU_ALU-1:0]    fu_vld_alu,
    input   logic       [NUM_FU_MULT-1:0]   fu_vld_mult,
    input   logic       [NUM_FU_STORE-1:0]  fu_vld_store,
    input   logic       [NUM_FU_LOAD-1:0]   fu_vld_load,
    input   ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu,
    input   ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult,
    input   ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store,
    input   ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load,

    input   logic           [N-1:0] c_en,
    input   PHYS_REG_IDX    [N-1:0] c_ts
);
    RS_ENTRY [RS_SZ-1:0] entries, entries_n;
    int num_free_fus [int];
    int cdb_tags [int];

    // always_ff @(posedge clock) begin
    //     if (reset || flush) begin
    //         entries <= '0;
    //     end else begin
    //         entries <= entries_n;
    //     end
    // end

    initial begin forever begin
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
                if (entries_n[rs].dat.t1 == c_ts[n]) begin
                    entries_n[rs].dat.t1_rdy = 1;
                end

                if (entries_n[rs].dat.t2 == c_ts[n]) begin
                    entries_n[rs].dat.t2_rdy = 1;
                end
            end
        end

        // issue
        num_free_fus[FU_ALU] = $countones(fu_rdy_alu);
        num_free_fus[FU_MULT] = $countones(fu_rdy_mult);
        num_free_fus[FU_STORE] = $countones(fu_rdy_store);
        num_free_fus[FU_LOAD] = $countones(fu_rdy_load);

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

        for (int n = 0, int rs = 0; n < N; ++n) begin
            if (!d_vld[n])
                continue;
            
            for (; rs < RS_SZ; ++rs) begin
                if (!entries_n[rs].busy)
                    continue;
                entries_n[rs].busy   = 1;
                entries_n[rs].issued = 0;
                entries_n[rs].dat    = d_dat[n];
                break;
            end
        end

        @(posedge clock);
    end end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            entries <= '0;
        end else begin
            entries <= entries_n;
        end
    end

    clocking cb @(posedge clock);
        property fuck;
            disable iff (reset || flush)
            entries == entries_dbg;
        endproperty
    endclocking

    task exit_on_error(input string msg);
        begin
            // print_failure();
            $display("\n\033[31m@@@ Failed at time %4d\033[0m", $time);
            $display("\033[31mError: %0s\033[0m\n\n", msg);
            $display("shit fest: %b", entries);
            $display("shit fest: %b", entries_dbg);
            $finish;
        end
    endtask


    AssignedSpotOneHot:  assert property(cb.fuck)     
        else exit_on_error ("fuck!");

endmodule


`endif // RS_SVA_SVH