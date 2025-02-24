`include "sys_defs.svh"

// `define fetch_cnt 19

module dispatch (
    input clock,
    input reset,
    input ID_EX_PACKET inst_fetched [`N-1:0],
    input RS_ENTRY rs_table [`RS_SZ-1:0],
    input [$clog(`ROB_SZ):0] rob_free,
    input [$clog(`LSQ_SZ):0] lsq_free,
    output [$bits(`RS_ENTRY)-1:0] next_rs [RS_SZ-1:0],
    output [$clog(`N):0] dispatch_cnt, //tells stage_if how many insts to dispatch
    output dispatch_vld //will be used to set if_valid to false if cnt == 0
    output INST ROB_isnts [`N:0]
);

logic [`RS_SZ-1:0] pos_vld;
// logic [$bits(`RS_ENTRY)-1:0] next_rs [RS_SZ-1:0];


always_comb begin
    
    //run this if we have an opening in the ROB and LSQ
    if ((rob_free > 0) && (lsq_free > 0)) begin
        //Find up to Superscaler width open entries in rs_table
        for (int i = 0; i < RS_SZ; i++) begin
            pos_vld[i] = rs_table[i].busy ? 0 : 1;
            dispatch_cnt = rs_table[i].busy ? dispatch_cnt : dispatch_cnt+1;
            if (dispatch_cnt >= `N) break;
        end

        //Set dispatch_cnt equal to the smallest # of openings between
        //RS, ROB, and LSQ
        if (rob_free > lsq_free) begin
            if (lsq_free < dispatch_cnt) dispatch_cnt = lsq_free;
        end
        else begin
            if (rob_free < dispatch_cnt) dispatch_cnt = rob_free;
        end
        dispatch_vld = (dispatch_cnt > 0) ? 1 : 0;

        //If we have open space to dispatch, do so
        if (dispatch_vld) begin
            int i = 0;
            for (int pos = 0; pos < RS_SZ; pos++) begin
                if pos_vld[pos] begin
                    next_rs[pos].busy = 1;
                    next_rs[pos].dat = id_ex_to_id_result(inst_fetched[i]);
                    next_rs[pos].issued = 0;
                    i += 1;
                    if (i > dispatch_cnt) break;
                end
            end
        end
        else begin
            next_rs = rs_table;
        end
    end
    //If no opening in ROB or LSQ, can immediately assign next_rs to rs_table
    else begin
        next_rs = rs_table;
        dispatch_vld = 0;
    end
end

// always_ff(@posedge clock) begin
//     if (reset) begin
//         rs_table <= '0;
//     end
//     else begin
//         rs_table <= next_rs;
//     end
// end

endmodule


task id_ex_to_id_result;
    input ID_EX_PACKET in;
    output ID_RESULT out;

    begin
        id_result.t             = 0; //implement later
        id_result.t1            = 0; //implement later
        id_result.t2            = 0; //implement later
        id_result.t1_rdy        = 0; //implement later
        id_result.t2_rdy        = 0; //implement later
        id_result.fu_idx        = 0; //implement later

        id_result.inst          = id_ex_packet.inst;
        id_result.PC            = id_ex_packet.PC;
        id_result.NPC           = id_ex_packet.NPC;

        id_result.rs1_value     = id_ex_packet.rs1_value;
        id_result.rs2_value     = id_ex_packet.rs2_value;

        id_result.opa_select    = id_ex_packet.opa_select;
        id_result.opb_select    = id_ex_packet.opb_select;

        id_result.dest_reg_idx  = id_ex_packet.dest_reg_idx;
        id_result.alu_func      = id_ex_packet.alu_func;
        id_result.mult          = id_ex_packet.mult;
        id_result.rd_mem        = id_ex_packet.rd_mem;
        id_result.wr_mem        = id_ex_packet.wr_mem;
        id_result.cond_branch   = id_ex_packet.cond_branch;
        id_result.uncond_branch = id_ex_packet.uncond_branch;
        id_result.halt          = id_ex_packet.halt;
        id_result.illegal       = id_ex_packet.illegal;
        id_result.csr_op        = id_ex_packet.csr_op;
    end
endtask