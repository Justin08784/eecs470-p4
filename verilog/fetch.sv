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
    DBG_icache dbg_icache,
    `endif

    input   clock,
    input   reset,
    input   flush,
    //input     [1:0] if_valid,       // only go to next PC when true
    input   decode2fetch d_in,
    input retire2fetch r_in,
    input MEM_BLOCK Imem_data,      // data coming back from Instruction memory


    input btb2fetch btb_in,
    input predictor2fetch pred_in,

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
    // INST [1:0] fifo_insns;

    //logic [1:0] valid_out;

    icache icache_0 (
        // inputs
        .clock                      (clock),
        .reset                      (reset),
        .flush                      (flush),
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

    // logic [$clog2(`N):0] if_valid_q;

    // fifo #(
    //     .DEPTH(16),
    //     .WIDTH($bits(INST)),
    //     .NUM_RPORTS(`N),
    //     .NUM_WPORTS(`N),
    //     .MAX_SCNT(`N)
    // ) dut (
    //     .clock      (clock),
    //     .reset      (reset),
    //     .wr_en_cnt  (free_scnt),
    //     .wr_data    (Imem_data),
    //     .rd_en_cnt  (d_in.d_rdy_cnt),
    //     .rd_data    (fifo_insns),
    //     .free_scnt  (free_scnt),
    //     .used_scnt  (used_scnt)
    // );

    // genvar i;
    // generate
    //     for (i = 0; i < N; i++) begin

    // Keep if valid until it gets valid data out
    // always_ff @(posedge clock) begin
    //     if (reset) begin
    //         if_valid_q <= '0;
    //     end else begin
    //         if_valid_q <= d_in.d_rdy_cnt || (if_valid_q && d_out.f_en_cnt == 0);
    //     end
    // end

    logic [$clog2(`N):0]    free_scnt, used_scnt, f_cnt;
    IF_ID_PACKET [`N-1:0]   f_dat;
    ADDR PC_reg_temp;

    logic vld;

    logic off; // 1 if PC is dw-misaligned (i.e. starts at 2nd word of double word)

    always_comb begin
        d_out.f_en_cnt = `MIN(used_scnt, d_in.d_rdy_cnt);
        off = PC_reg[2]; 
        f_cnt = !icache_valid ? 0 : (off ? `MIN(1, free_scnt) : free_scnt);

        for (int unsigned i = 0, logic vld = 0; i < `N; ++i) begin
            vld = i < f_cnt;
            PC_reg_temp = PC_reg + 4*i;
            f_dat[i] = '{
                inst  : vld ? icache_out.word_level[PC_reg_temp[2]] : `NOP,
                PC    : PC_reg_temp,
                NPC   : PC_reg_temp + 4,
                valid : vld,
                bhr   : pred_in.bhr
            };
            $display("DECODE PC: %x", PC_reg[i]);
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

    logic [1:0] predict_taken;

    logic [1:0] mux_result_prediction; 

    logic [1:0] btb_hit;

    logic [1:0] [15:0] btb_target;

    assign mux_result_prediction[0] = /*predict_taken[0] &&*/ btb_hit[0];

   // assign pred_out = mux_result
    assign mux_result_prediction[1] = /*predict_taken[1] &&*/ btb_hit[1];

    //if btb

    logic [4:0] taken_count;

    assign btb_hit = btb_in.hit;

   /* always_comb begin
     $display("btb_hit: %2b", btb_hit);
    end

    always_comb begin
        $display("PC REG COMB: %x", PC_reg);
    end*/

    always_ff @(posedge clock) begin
        if (reset) begin
            //foreach(PC_reg[i])
                PC_reg <= 0; // initial PC value is 0 (the memory address where our program starts)
                taken_count = 5'b0;
                //mux_result_prediction <= 2'b00;
        end else if (flush) begin
                PC_reg <= r_in.corrected_PC;  // initial PC value is 0 (the memory address where our program starts)
        end else if(mux_result_prediction[0]) begin
                $display("PREDICTING TAKEN:");
                taken_count = taken_count + 1;
               // foreach(PC_reg[i])
                 //   PC_reg[i] <= 24;
                //PC_reg[1] <= 24;
                //$display("TAKEN COUNT: %5x", taken_count);
                $display("MUX RESULT: %1x", mux_result_prediction[0]);
                //$display("PREDICT TAKEN: %1x", predict_taken[0]);
               // $display("BTB HIT: %1x", btb_hit[0]);
                $display("FETCHING NEW TARGET: %x", btb_in.target);
                //foreach(PC_reg[i])
                //PC_reg <=  mux_result_prediction[i] ? {16'b0,btb_in.target[i]} : PC_reg[i] + 4*f_cnt;
        end else begin
            foreach(PC_reg[i])
                PC_reg <= PC_reg + 4*f_cnt; // ...or transition to next PC if valid
        end 
    end


    assign btb_out.target = r_in.corrected_PC;
    assign btb_out.is_taken = r_in.is_taken;
    assign btb_out.correct_PC =  r_in.PC;

    assign btb_out.PC =  /*r_in.update_enable ? r_in.PC :*/ PC_reg;


    assign btb_target = btb_in.target;


    assign pred_out.PC = /*r_in.update_enable ? r_in.PC :*/ PC_reg;
    assign pred_out.update_enable = r_in.update_enable;
    assign pred_out.taken = r_in.is_taken;
    assign pred_out.correct_PC =  r_in.PC;
    assign pred_out.retired_bhr = r_in.retired_bhr;
     
    assign predict_taken = pred_in.prediction;

    // debugging
    `ifdef DEBUG
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | >> Fetch >>", $time);
            $display("r_in: {flush: %b, corrected_PC: 0x%x}", flush, r_in.corrected_PC);
            $display("PC_reg:  %x", PC_reg);
            $display("Imem_data: %x", Imem_data);

            $display("FETCH2BTB: PC: %x", PC_reg);
            //btb_out.target <= r_in.corrected_PC[15:0];

            $display("FETCH RECEIVED CORRECT PC: %x", r_in.corrected_PC);
            $display("SEND_TAKEN_TO_BTB: %2b", r_in.is_taken);
            $display("FETCH RECEIVED ORIGINAL PC: %x", r_in.PC);
           // $display("BTB TARGET: %x", r_in.corrected_PC[15:0]);


            $display("FETCH2PRED: PC: %x", PC_reg);
            $display("FETCH2PRED UPDATE ENABLE: %x", r_in.update_enable);
            $display("FETCH2PRED TAKEN: %x", r_in.is_taken);
            $display("FETCH2PRED CORRECT_PC: %x", r_in.PC);
            $display("FETCH2PRED RETIRED_BHR0: %b", r_in.retired_bhr[0]);
            $display("FETCH2PRED RETIRED_BHR1: %b", r_in.retired_bhr[1]);


           $display("  %3d | << Fetch <<", $time);  
        end
    end
    `endif // DEBUG

    // //RE-EVALUATE
    // // assign valid_out = icache_valid ? (if_valid_q) : '0 && (if_valid_q[0] || if_valid_q[1]);
    // // assign valid_out[1] = icache_valid && if_valid_q[1] && (PC_reg % 8 == 0);

    `ifdef DEBUG
    assign dbg = '{
        flush,
        d_in,
        d_out,
        r_in,
        Imem_data,
        PC_reg,
        dbg_icache
    };
    `endif

endmodule // stage_if
