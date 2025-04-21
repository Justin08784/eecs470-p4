/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  stage_if.sv                                         //
//                                                                     //
//  Description :  instruction fetch (IF) stage of the pipeline;       //
//                 fetch instruction, compute next PC location, and    //
//                 send them down the pipeline.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "sys_defs.svh"

module stage_if_p4 (
    `ifdef DEBUG
    output DBG_fetch dbg,
    `endif

    input   clock,
    input   reset,
    input   flush,
    //input     [1:0] if_valid,       // only go to next PC when true
    input   decode2fetch d_in,
    input retire2fetch r_in,
    input MEM_BLOCK Imem_data,      // data coming back from Instruction memory


    input btb2fetch btb_in,
    input predictor2fetch pred_in_gshare,
    input predictor2fetch pred_in_corr,

    output fetch2btb btb_out,
    output fetch2predictor pred_out,
    // tags from memory
    input MEM_TAG  Imem2proc_transaction_tag, // Should be zero unless there is a response
    input MEM_TAG  Imem2proc_data_tag,

    output MEM_COMMAND  Imem_command, // Command sent to memory
    output ADDR         Imem_addr, // address sent to Instruction memory
    output  fetch2decode d_out
);

    ADDR PC_reg; // PCs we are currently fetching
    MEM_BLOCK icache_out;
    logic  icache_valid;
    logic [1:0] corr_pred;
    logic [1:0] mux_result_prediction; 
    logic [1:0] predict_taken;
    logic [1:0] btb_hit;
    logic [1:0] [15:0] btb_target;

    assign btb_hit = btb_in.hit;
    assign mux_result_prediction = predict_taken & btb_hit;

    DBG_icache dbg_icache;
    icache icache_0 (
        `ifdef DEBUG
        .dbg(dbg_icache),
        `endif
        // inputs
        .clock                      (clock),
        .reset                      (reset),
        .flush                      (flush),
        .branch_pred                (mux_result_prediction[0]),
        .Imem2proc_transaction_tag  (Imem2proc_transaction_tag),
        .Imem2proc_data             (Imem_data),
        .Imem2proc_data_tag         (Imem2proc_data_tag),
        .proc2Icache_addr           (PC_reg),
        // outputs
        .proc2Imem_command          (Imem_command),
        .proc2Imem_addr             (Imem_addr),
        .Icache_data_out            (icache_out), // Data is mem[proc2Icache_addr]
        .Icache_valid_out           (icache_valid) // When valid is high
    );


    logic [$clog2(`N):0]    free_scnt, used_scnt, f_cnt;
    IF_ID_PACKET [`N-1:0]   f_dat;
    ADDR PC_reg_temp;

    logic base_woff; // 1 if PC is dw-misaligned (i.e. starts at 2nd word of double word)
    always_comb begin
        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);
        base_woff = PC_reg[2]; 
        f_cnt = 0;
        if (!icache_valid) begin
            f_cnt = 0;
        end else if (base_woff || |mux_result_prediction) begin
            f_cnt = 1;
        end else begin
            f_cnt = 2;
        end
        f_cnt = `MIN(f_cnt, free_scnt);

        for (int unsigned i = 0; i < `N; ++i) begin
            PC_reg_temp = PC_reg + 4*i;
            f_dat[i] = '{
                inst  : icache_out.word_level[PC_reg_temp[2]],
                PC    : PC_reg_temp,
                NPC   : PC_reg_temp + 4,
                bhr   : pred_in_gshare.bhr,
                pred_tgt : btb_in.hit[i] ? btb_in.target[i] : 0,

                correlated_bhr  : pred_in_corr.bhr,
                pred            : mux_result_prediction[i],
                gshare_pred     : pred_in_gshare.prediction[i],
                corr_pred       : pred_in_corr.prediction[i]
            };
        end
    end

    fifo #(
        .DEPTH(4*`N),
        .WIDTH($bits(IF_ID_PACKET)),
        .NUM_RPORTS(`N),
        .NUM_WPORTS(`N),
        .ENABLE_INTR_FWD(`FALSE),
        .INSTANCE_ID(2)
    ) dut (
        .clock      (clock),
        .reset      (reset),
        .flush      (flush),
        .wr_en_cnt  (f_cnt),
        .wr_data    (f_dat),
        .rd_en_cnt  (d_out.f_en_cnt),
        .rd_data    (d_out.f_dat),
        .free_scnt  (free_scnt),
        .used_scnt  (used_scnt)
    );

    logic [4:0] spec_branch_count;


    always_ff @(posedge clock) begin
        if (reset) begin
                PC_reg <= 0; // initial PC value is 0 (the memory address where our program starts)
                spec_branch_count <= 0;
        end else if (flush) begin
                PC_reg <= r_in.corrected_PC;
                spec_branch_count <= 0;
        end else if(mux_result_prediction) begin
            if(mux_result_prediction[0]) begin
                if (f_cnt > 0) begin
                    PC_reg <= {16'b0, btb_in.target[0]};
                    spec_branch_count <= spec_branch_count + 1;
                end else begin
                    PC_reg <= PC_reg;
                    spec_branch_count <= spec_branch_count;
                end
            end else if(mux_result_prediction[1]) begin
                PC_reg <= PC_reg + 4*f_cnt;
                spec_branch_count <= spec_branch_count;
            end
        end else begin
                PC_reg <= PC_reg + 4*f_cnt; 
                spec_branch_count <= spec_branch_count;
        end 
    end


    assign btb_out.target = r_in.corrected_PC;
    assign btb_out.is_taken = r_in.is_taken;
    assign btb_out.correct_PC =  r_in.PC;
    assign btb_out.PC[0] =  PC_reg;
    assign btb_out.PC[1] = PC_reg + 4; 

    assign btb_target = btb_in.target;


    assign pred_out.PC[0] =  PC_reg;
    assign pred_out.PC[1] = PC_reg + 4;
    assign pred_out.update_enable = r_in.update_en;
    assign pred_out.taken = r_in.is_taken;
    assign pred_out.correct_PC =  r_in.PC;
    assign pred_out.retired_bhr = r_in.retired_bhr;
    assign pred_out.correlated_bhr = r_in.correlated_bhr;

    assign pred_out.mispred_taken = r_in.mispred_taken;

    assign pred_out.spec_branch_count = spec_branch_count;
    assign pred_out.flush = flush;

    logic [1:0] gshare_pred;
    logic [255:0][1:0] chooser_table;


    
   always_comb begin
        case (chooser_table[PC_reg[7:0]])
            2'b00: predict_taken = pred_in_gshare.prediction;
            2'b01: predict_taken = pred_in_gshare.prediction;
            2'b10: predict_taken = pred_in_corr.prediction;
            2'b11: predict_taken = pred_in_corr.prediction;
            default: predict_taken = '0;
        endcase
    end

    logic g_correct, c_correct;
    logic [7:0] idx;

   //Update chooser table on retirement
    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < 256; i++) begin
                chooser_table[i] <= 2'b10; 
            end
        end else begin
            for (int i = 0; i < 2; i++) begin
                g_correct = (r_in.gshare_pred[i] == r_in.is_taken[i]);
                c_correct = (r_in.corr_pred[i] == r_in.is_taken[i]);
                idx = r_in.PC[i][7:0];

                // Only update chooser if one was right and one was wrong
                if (g_correct && !c_correct && chooser_table[idx] != 2'b00)
                    chooser_table[idx] <= chooser_table[idx] - 1;
                else if (!g_correct && c_correct && chooser_table[idx] != 2'b11)
                    chooser_table[idx] <= chooser_table[idx] + 1;
            end
        end
    end



    // debugging
    `ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | >> Fetch >>", $time);
            $display("r_in: {flush: %b, corrected_PC: 0x%x}", flush, r_in.corrected_PC);
            $display("PC_reg:  %x", PC_reg);
            $display("Imem_data: %x", Imem_data);

            $display("FETCH2BTB: PC: %x", PC_reg);
            $display("FETCH2BTB: PC: %x", PC_reg+4);


            $display("BTB2FETCH: HIT: %x", btb_in.hit[0]);
            $display("BTB2FETCH: HIT: %x", btb_in.hit[1]);
  
            $display("BTB2FETCH: TARGET0: %x", btb_in.target[0]);
            $display("BTB2FETCH: TARGET1: %x", btb_in.target[1]);
            //btb_out.target <= r_in.corrected_PC[15:0];

            $display("FETCH RECEIVED CORRECT PC: %x", r_in.corrected_PC);
           // $display("SEND_TAKEN_TO_BTB: %2b", r_in.is_taken);
           // $display("FETCH RECEIVED ORIGINAL PC: %x", r_in.PC);
           // $display("BTB TARGET: %x", r_in.corrected_PC[15:0]);


            $display("FETCH2PRED: PC0: %x", PC_reg);
            $display("FETCH2PRED: PC1: %x", PC_reg+4);
            $display("FETCH2PRED UPDATE ENABLE: %2b", r_in.update_en);
            $display("FETCH2PRED TAKEN: %2b", r_in.is_taken);
            $display("FETCH2PRED CORRECT_PC: %x", r_in.PC);
            $display("FETCH2PRED RETIRED_BHR0: %b", r_in.retired_bhr[0]);
            $display("FETCH2PRED RETIRED_BHR1: %b", r_in.retired_bhr[1]);


            $display("GSHARE PRED: %b", pred_in_gshare.prediction);
            $display("CORR PRED: %b", pred_in_corr.prediction);

            $display("RET_CORR BHR: %b", r_in.correlated_bhr);
            $display("PRED_IN_CORR BHR: %b", pred_in_corr.bhr);

            $display("DECODE PC: %x", PC_reg_temp);
            $display("F_DAT PRED: %x", mux_result_prediction[0]);

            $display("F_COUNT: %x", f_cnt);
            //$display(": %x", mux_result_prediction[0]);


           $display("  %3d | << Fetch <<", $time);  
        end
    end
    `endif // DEBUG

    // //RE-EVALUATE
    // // assign valid_out = icache_valid ? (if_valid_q) : '0 && (if_valid_q[0] || if_valid_q[1]);
    // // assign valid_out[1] = icache_valid && if_valid_q[1] && (PC_reg % 8 == 0);

    `ifdef DEBUG
    assign dbg = '{
        flush : flush,
        d_in  : d_in,
        d_out : d_out,
        r_in  : r_in,
        Imem_data : Imem_data,
        PC_reg : PC_reg,
        dbg_icache:dbg_icache
    };
    `endif

endmodule // stage_if