
`include "sys_defs.svh"
`include "test/rs_sva.svh"
/*
CLARIFICATION NEEDED:
Ok, checking the accuracy of FF state like entries_dbg seems pretty
straightforward. But how to check correctness of combinational stuff like
s_vld, rs_scnt? Aren't there timing issues?
*/
localparam int N = 2;
localparam int RS_SZ = 8;
localparam int FU_IDX_NUM = `FU_IDX_NUM;
localparam int NUM_FU_ALU = 1;
localparam int NUM_FU_MULT = 2;
localparam int NUM_FU_STORE = 4;
localparam int NUM_FU_LOAD = 4;


typedef struct packed {
    logic       [$clog2(N):0]       rs_scnt; // to dispatcher
    logic       [NUM_FU_ALU-1:0]    fu_vld_alu;
    logic       [NUM_FU_MULT-1:0]   fu_vld_mult;
    logic       [NUM_FU_STORE-1:0]  fu_vld_store;
    logic       [NUM_FU_LOAD-1:0]   fu_vld_load;
    ID_RESULT   [NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT   [NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT   [NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT   [NUM_FU_LOAD-1:0]   fu_dat_load;
} RS_OUTS;

RS_OUTS model_out;
function int model_update(
    // input   clock,
    input   reset,
    input   flush,

    // dispatch
    input   logic       [$clog2(N):0]       rs_scnt, // to dispatcher
    input   logic       [N-1:0]             d_vld,     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    input   ID_RESULT   [N-1:0]             d_dat,

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
    static RS_ENTRY [RS_SZ-1:0] entries;

    if (reset || flush) begin
        entries = '0;
    end

endfunction


module rs_testbench;
    // constants

    // signals
    logic clock;
    logic reset;
    logic flush;
    RS_ENTRY [RS_SZ-1:0] entries_dbg;

    logic           [$clog2(N):0] rs_scnt; // to dispatcher
    logic           [N-1:0] d_vld;     // which dispatch lines are valid? (from dispatcher; dep. on rs_scnt)
    ID_RESULT       [N-1:0] d_dat;
    // issue
    logic           [NUM_FU_ALU-1:0]    fu_rdy_alu;
    logic           [NUM_FU_MULT-1:0]   fu_rdy_mult;
    logic           [NUM_FU_STORE-1:0]  fu_rdy_store;
    logic           [NUM_FU_LOAD-1:0]   fu_rdy_load;

    logic           [NUM_FU_ALU-1:0]    fu_vld_alu;
    logic           [NUM_FU_MULT-1:0]   fu_vld_mult;
    logic           [NUM_FU_STORE-1:0]  fu_vld_store;
    logic           [NUM_FU_LOAD-1:0]   fu_vld_load;
    ID_RESULT       [NUM_FU_ALU-1:0]    fu_dat_alu;
    ID_RESULT       [NUM_FU_MULT-1:0]   fu_dat_mult;
    ID_RESULT       [NUM_FU_STORE-1:0]  fu_dat_store;
    ID_RESULT       [NUM_FU_LOAD-1:0]   fu_dat_load;
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
        .FU_IDX_NUM(FU_IDX_NUM),
        .NUM_FU_ALU(NUM_FU_ALU),
        .NUM_FU_MULT(NUM_FU_MULT),
        .NUM_FU_STORE(NUM_FU_STORE),
        .NUM_FU_LOAD(NUM_FU_LOAD)
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

        .fu_rdy_alu(fu_rdy_alu),
        .fu_rdy_mult(fu_rdy_mult),
        .fu_rdy_store(fu_rdy_store),
        .fu_rdy_load(fu_rdy_load),

        .fu_vld_alu(fu_vld_alu),
        .fu_vld_mult(fu_vld_mult),
        .fu_vld_store(fu_vld_store),
        .fu_vld_load(fu_vld_load),
        .fu_dat_alu(fu_dat_alu),
        .fu_dat_mult(fu_dat_mult),
        .fu_dat_store(fu_dat_store),
        .fu_dat_load(fu_dat_load),

        .c_en(c_en),
        .c_ts(c_ts)
    );

    bind rs_dut rs_sva # (
        .N(N),
        .RS_SZ(RS_SZ),
        .FU_IDX_NUM(FU_IDX_NUM),
        .NUM_FU_ALU(NUM_FU_ALU),
        .NUM_FU_MULT(NUM_FU_MULT),
        .NUM_FU_STORE(NUM_FU_STORE),
        .NUM_FU_LOAD(NUM_FU_LOAD)
    ) dut_sva (
        .clock(clock),
        .reset(reset),
        .flush(1'b0),
        .entries_dbg(entries_dbg),
        .free_gnt_bus_dbg(free_gnt_bus_dbg),
        .d_gnt_bus_dbg(d_gnt_bus_dbg),

        .rs_scnt(rs_scnt),
        .d_vld(d_vld),
        .d_dat(d_dat),

        .fu_rdy_alu(fu_rdy_alu),
        .fu_rdy_mult(fu_rdy_mult),
        .fu_rdy_store(fu_rdy_store),
        .fu_rdy_load(fu_rdy_load),

        .fu_vld_alu(fu_vld_alu),
        .fu_vld_mult(fu_vld_mult),
        .fu_vld_store(fu_vld_store),
        .fu_vld_load(fu_vld_load),
        .fu_dat_alu(fu_dat_alu),
        .fu_dat_mult(fu_dat_mult),
        .fu_dat_store(fu_dat_store),
        .fu_dat_load(fu_dat_load),

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
        d_dat[i].t2_rdy = t2_rdy;
        d_dat[i].fu_idx = fu_idx;
    endtask

    task clr_dispatch(
        input int i
    );
        d_vld[i] = 0;
        d_dat[i] = '0;
    endtask

    task set_cdb(
        input int i,
        input int t
    );
        c_en[i] = 1;
        c_ts[i]  = t;
    endtask

    task clr_cdb(
        input int i
    );
        c_en[i] = 0;
        c_ts[i]  = '0;
    endtask

    task set_fu(
        input FU_IDX fu,
        input int i
    );
        case (fu)
            FU_ALU:     fu_rdy_alu[i]   = 1;
            FU_MULT:    fu_rdy_mult[i]  = 1;
            FU_LOAD:    fu_rdy_load[i]  = 1;
            FU_STORE:   fu_rdy_store[i] = 1;
        endcase
    endtask

    task clr_fu(
        input FU_IDX fu,
        input int i
    );
        case (fu)
            FU_ALU:     fu_rdy_alu[i]   = 0;
            FU_MULT:    fu_rdy_mult[i]  = 0;
            FU_LOAD:    fu_rdy_load[i]  = 0;
            FU_STORE:   fu_rdy_store[i] = 0;
        endcase
    endtask

    task marker();
        static int i = 0;
        $display("~~~~ %d !!!!", i++);
    endtask

    task get_fu_name(input FU_IDX fu_idx, output string name);
        case (fu_idx)
            FU_ALU:     name = "ALU";
            FU_MULT:    name = "MULT";
            FU_LOAD:    name = "LOAD";
            FU_STORE:   name = "STORE";
            default:    name = "Unknown FU";
        endcase
    endtask

    task print_entries();
        for (int i = 0; i < RS_SZ; ++i) begin
            string fu_name;
            get_fu_name(entries_dbg[i].dat.fu_idx, fu_name);
            $display("Entry [%0d]: busy=%b, issued=%b, t=%0d, t1=%0d, t2=%0d, t1_rdy=%b, t2_rdy=%b, fu=%s(%0d)",
                i, 
                entries_dbg[i].busy, 
                entries_dbg[i].issued, 
                entries_dbg[i].dat.t, 
                entries_dbg[i].dat.t1, 
                entries_dbg[i].dat.t2, 
                entries_dbg[i].dat.t1_rdy, 
                entries_dbg[i].dat.t2_rdy, 
                
                entries_dbg[i].busy ? fu_name : "*",
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


    task test_1inst();
        reset   = 1;
        @(negedge clock);
        @(negedge clock);

        reset = 0;
        @(negedge clock);

        set_dispatch(1, 2, 4, 0, 0, 1);
        @(posedge clock);
        // $display("s_vld: %b", s_vld);
        @(negedge clock);
        marker();
        print_entries();

        clr_dispatch(0);
        clr_dispatch(1);
        set_cdb(0, 1);
        set_cdb(1, 2);
        @(posedge clock);
        @(negedge clock);
        marker();
        print_entries();

        // ask about timing; why does s_vld display need to be after posedge?
        clr_cdb(0);
        clr_cdb(1);
        set_fu(FU_ALU, 0);
        @(posedge clock);
        @(negedge clock);
        marker();
        print_entries();

        @(posedge clock);
        @(negedge clock);
        marker();
        print_entries();


    endtask
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
        clock           = 0;
        failed          = 0;
        d_vld           = '0;
        d_dat           = '0;
        fu_rdy_alu      = '0;
        fu_rdy_mult     = '0;
        fu_rdy_store    = '0;
        fu_rdy_load     = '0;
        c_en            = '0;
        c_ts            = '0;

        // test_1inst();
        reset = 1;
        @(negedge clock);
        @(negedge clock);
        reset = 0;
        @(negedge clock);
        @(negedge clock);


        // @(negedge clock);
        // marker();
        // print_entries();

        if (failed)
            $display("@@@ Failed\n");
        else
            $display("@@@ Passed\n");

        $finish;
    end

endmodule
