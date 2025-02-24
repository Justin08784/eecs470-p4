
`include "sys_defs.svh"

module rs_testbench;
    // constants
    localparam int N = 2;
    localparam int RS_SZ = 8;
    localparam int FU_IDX_NUM = 2;

    // signals
    logic clock;
    logic reset;
    logic flush;
    RS_ENTRY [RS_SZ-1:0] entries_dbg;

    logic           [$clog2(N):0] rs_scnt; // to dispatcher
    logic           [N-1:0] d_vld;     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    ID_RESULT       [N-1:0] d_dat;
    // issue
    logic           [FU_IDX_NUM-1:0][$clog2(N):0] fu_scnt; // functional unit availability; saturating counters that cap at N
    logic           [N-1:0] s_vld;     // which issue lines are valid? (dep. on fu_scnt)
    ID_RESULT       [N-1:0] s_dat;
    // complete (CDB)
    logic           [N-1:0] c_en;
    PHYS_REG_IDX    [N-1:0] c_t;

    logic failed;
    // DATA r1, r2, correct_r, mul_r;
    string fmt;

    logic [N-1:0][RS_SZ-1:0] free_gnt_bus_dbg;
    logic [N-1:0][RS_SZ-1:0] d_gnt_bus_dbg;

    rs # (
        .N(N),
        .RS_SZ(RS_SZ),
        .FU_IDX_NUM(FU_IDX_NUM)
    ) rs_dut(
        .clock(clock),
        .reset(reset),
        .flush(1'b0),
        .entries_dbg(entries_dbg),
        .free_gnt_bus_dbg(free_gnt_bus_dbg),
        .d_gnt_bus_dbg(d_gnt_bus_dbg),

        .rs_scnt(rs_scnt),
        .d_vld(d_vld),
        .d_dat(d_dat),

        .fu_scnt(fu_scnt),
        .s_vld(s_vld),
        .s_dat(s_dat),

        .c_en(c_en),
        .c_ts(c_t)
    );

    task dispatch(
        input int i,
        input ID_RESULT inst
    );
        begin
            // Set up a valid dispatch line; adjust as needed.
            d_vld[i] = 1;
            d_dat[i] = '1;
        end
    endtask

    task print_entries();
        for (int i = 0; i < RS_SZ; ++i) begin
            $display("Entry [%0d]: busy=%b, issued=%b, t=%0d, t1=%0d, t2=%0d, t1_rdy=%b, t2_rdy=%b, fu_idx=%0d",
                i, 
                entries_dbg[i].busy, 
                entries_dbg[i].issued, 
                entries_dbg[i].dat.t, 
                entries_dbg[i].dat.t1, 
                entries_dbg[i].dat.t2, 
                entries_dbg[i].dat.t1_rdy, 
                entries_dbg[i].dat.t2_rdy, 
                entries_dbg[i].dat.fu_idx
                // entries_dbg[i].dat.PC, 
                // entries_dbg[i].dat.NPC, 
                // entries_dbg[i].dat.alu_func, 
                // entries_dbg[i].dat.mult, 
                // entries_dbg[i].dat.rd_mem, 
                // entries_dbg[i].dat.wr_mem, 
                // entries_dbg[i].dat.cond_branch, 
                // entries_dbg[i].dat.uncond_branch, 
                // entries_dbg[i].dat.halt, 
                // entries_dbg[i].dat.illegal, 
                // entries_dbg[i].dat.csr_op
            );
        end
    endtask

    always begin
        #(`CLOCK_PERIOD/2.0);
        clock = ~clock;
    end

    initial begin
        clock = 0;
        reset = 1;
        failed = 0;
        d_vld = '0;

        @(negedge clock);
        @(negedge clock);
        $display("**0");
        print_entries();
        $display("rs_scnt: %b", rs_scnt);
        for (int i = 0; i < N; ++i) begin
            $display("%b", free_gnt_bus_dbg[i]);
        end
        for (int i = 0; i < N; ++i) begin
            $display("d_gnt_bus: %b", d_gnt_bus_dbg[i]);
        end
        reset = 0;
        @(negedge clock);

        $display("**1");
        print_entries();
        $display("rs_scnt: %b", rs_scnt);
        for (int i = 0; i < N; ++i) begin
            $display("%b", free_gnt_bus_dbg[i]);
        end
        for (int i = 0; i < N; ++i) begin
            $display("d_gnt_bus: %b", d_gnt_bus_dbg[i]);
        end

        // dispatch(0, '0);
        // dispatch(1, '0);

        @(negedge clock);
        $display("**2");
        print_entries();
        $display("rs_scnt: %b", rs_scnt);
        for (int i = 0; i < N; ++i) begin
            $display("%b", free_gnt_bus_dbg[i]);
        end
        for (int i = 0; i < N; ++i) begin
            $display("d_gnt_bus: %b", d_gnt_bus_dbg[i]);
        end

        @(negedge clock);

        if (failed)
            $display("@@@ Failed\n");
        else
            $display("@@@ Passed\n");

        $finish;
    end

endmodule
