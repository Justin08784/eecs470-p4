
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
    PHYS_REG_IDX    [N-1:0] c_ts;

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
        .c_ts(c_ts)
    );

    task set_dispatch(
        input int i,
        input int t1,
        input int t2,
        input int t1_rdy,
        input int t2_rdy,
        input int fu_idx
    );
        // Set up a valid dispatch line
        d_vld[i]        = 1;

        d_dat[i]        = '0;
        d_dat[i].t1     = t1;
        d_dat[i].t2     = t2;
        d_dat[i].t1_rdy = t1_rdy;
        d_dat[i].t1_rdy = t2_rdy;
        d_dat[i].fu_idx = fu_idx;
    endtask

    task clr_dispatch(
        input int i
    );
        d_vld[i] = 0;
        d_dat[i] = '0;
    endtask

    task marker();
        static int i = 0;
        $display("~~~~ %d !!!!", i++);
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
        /* some unused debugs */
        // $display("rs_scnt: %b", rs_scnt);
        // for (int i = 0; i < N; ++i) begin
        //     $display("%b", free_gnt_bus_dbg[i]);
        // end
        // for (int i = 0; i < N; ++i) begin
        //     $display("d_gnt_bus: %b", d_gnt_bus_dbg[i]);
        // end

        /* initialize */
        clock   = 0;
        failed  = 0;
        d_vld   = '0;
        d_dat   = '0;
        fu_scnt = '1;
        c_en    = '0;
        c_ts    = '0;

        reset   = 1;
        @(negedge clock);
        @(negedge clock);

        reset = 0;
        @(negedge clock);

        set_dispatch(0, 1, 2, 0, 0, 0);
        set_dispatch(1, 2, 4, 0, 0, 1);
        @(negedge clock);
        marker();
        print_entries();

        clr_dispatch(0);
        clr_dispatch(1);
        @(negedge clock);
        marker();
        print_entries();

        if (failed)
            $display("@@@ Failed\n");
        else
            $display("@@@ Passed\n");

        $finish;
    end

endmodule
