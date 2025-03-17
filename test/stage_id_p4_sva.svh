`ifndef STAGE_ID_P4_SVA_SVH
`define STAGE_ID_P4_SVA_SVH

module stage_id_p4_sva (
    input   clock,
    input   reset,

    input   fetch2decode f_in,
    input   decode2fetch f_out,

    input   dispatch2decode d_in,
    input   decode2dispatch d_out
    // output ID_EX_PACKET id_packet
);
    localparam DEPTH = 2*`N;

    int     rd_count; // number of reads complete
    int     wr_count; // number of writs complete
    logic   [$clog2(DEPTH):0] used;    // how full the buffer should be
    logic   [$clog2(DEPTH):0] free;    // how full the buffer should be
    assign  free = DEPTH - used;


    decode2dispatch f_out_delayed;
    decode2dispatch d_out_delayed;
    initial begin
        // wait until 1st reset: ensures no Xs are floating around
        // (if there are Xs we get errors like indexing with Xs into assoc. arrays)
        // while (!reset)
        //     @(negedge clock);
        @(negedge clock);   
        @(negedge clock);   
    forever begin
        // for (int i = 0; i < wr_en_cnt; ++i) begin
        //     entries.push_back(wr_data[i]);
        // end

        // rd_data_sva = '0;
        // for (int i = 0; i < rd_en_cnt; ++i) begin
        //     rd_data_sva[i] = entries.pop_front();
        // end
        // #0

        /*
        This #1step ensures that when the property checks d_out in the same cycle that new data is written, 
        it will see the forwarded value (instead of seeing the old/stale value too early).

        But why the fuck don't we need this for fifo_sva.svh????
        */
        #1step f_out_delayed = f_out; 
        #1step d_out_delayed = d_out; 
        @(posedge clock);
        @(negedge clock);
    end
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            rd_count    <= 0;
            wr_count    <= 0;
            used        <= 0;
        end else begin
            rd_count    <= rd_count + d_in.dispatch_en_cnt;
            wr_count    <= wr_count + f_in.f_en_cnt;
            used        <= used + f_in.f_en_cnt - d_in.dispatch_en_cnt;
        end
    end

    task exit_on_error;
        begin
            $display("f_cnt: %d d_cnt: %d", f_in.f_en_cnt, d_in.dispatch_en_cnt);
            $display("  %3d | d_in: PC[%x, %x] inst[%x, %x] wr_en_cnt: %d  rd_en_cnt: %d  |  d_out: PC[%x, %x] inst[%x,%x]",
                $time,
                f_in.f_en_cnt > 0 ? f_in.f_dat[0].PC : 0,
                f_in.f_en_cnt > 1 ? f_in.f_dat[1].PC : 0,
                f_in.f_en_cnt > 0 ? f_in.f_dat[0].inst : 0,
                f_in.f_en_cnt > 1 ? f_in.f_dat[1].inst : 0,
                f_in.f_en_cnt,
                d_in.dispatch_en_cnt,
                d_out.d_dat[0].PC, 
                d_out.d_dat[1].PC,
                d_out.d_dat[0].inst, 
                d_out.d_dat[1].inst
            );
            $display("\n\033[31m@@@ Failed at time %4d\033[0m\n", $time);
            // $display("used %d free %d us %d fs %d reset: %b", used, free, used_scnt, free_scnt, reset);
            $finish;
        end
    endtask

    clocking cb @(posedge clock);
        property rd_en_correct;
            disable iff (reset)
            d_in.dispatch_en_cnt <= used + f_in.f_en_cnt;
        endproperty

        property wr_en_correct;
            disable iff (reset)
            f_in.f_en_cnt <= free + d_in.dispatch_en_cnt;
        endproperty

        // property used_scnt_correct;
        //     disable iff (reset)
        //     used_scnt == used < NUM_RPORTS ? used : NUM_RPORTS;
        // endproperty

        // property free_scnt_correct;
        //     disable iff (reset)
        //     free_scnt == free < NUM_WPORTS ? free : NUM_WPORTS;
        // endproperty

        // property rd_data_correct;
        //     disable iff (reset)
        //     rd_data == rd_data_sva;
        // endproperty

        property write_read_correctly(i);
            INST inst_in;
            ADDR PC_in;
            int  idx;
            (f_in.f_en_cnt > i, inst_in=f_in.f_dat[i].inst, PC_in=f_in.f_dat[i].PC, idx=(rd_count + used + i),
                $display("INP f_en_cnt: %d, i: %0d, f_in[%0d].PC: %x, rd_count: %0d, used: %0d, idx: %0d",
                    f_in.f_en_cnt,
                    i,
                    i,
                    f_in.f_dat[i].PC,
                    rd_count,
                    used,
                    idx
                )
            ) // value is written
            ##[0:$] (d_in.dispatch_en_cnt > 0 && rd_count <= idx && idx < rd_count + d_in.dispatch_en_cnt,
                $display("CHK d_en_cnt: %d, PC: [%x, %x], rd_count: %0d, used: %0d",
                    d_in.dispatch_en_cnt,
                    d_out.d_dat[0].PC,
                    d_out.d_dat[1].PC,
                    rd_count,
                    used
                )
            ) // wait for previous entries to be read
            |-> (
                d_out_delayed.d_dat[idx - rd_count].PC === PC_in
                && d_out_delayed.d_dat[idx - rd_count].inst === inst_in
                && d_out_delayed.d_dat[idx - rd_count].id === rd_count + idx - rd_count // ensures id increments
            );
        endproperty

    endclocking

    // Assert properties
    RdEn: assert property(cb.rd_en_correct)
        else exit_on_error;
    WrEn: assert property(cb.wr_en_correct)
        else exit_on_error;
    // UsedScnt: assert property(cb.used_scnt_correct)
    //     else exit_on_error;
    // FreeScnt: assert property(cb.free_scnt_correct)
    //     else exit_on_error;
    // RdData: assert property(cb.rd_data_correct)
    //     else exit_on_error;
    generate
        for (genvar wr_port = 0; wr_port < `N; ++wr_port) begin : gen_wr_props
            assert property(cb.write_read_correctly(wr_port))
                else exit_on_error;
        end
    endgenerate

endmodule


`endif // STAGE_ID_P4_SVA_SVH