module prf #(
    parameter WIDTH      = 32,
    parameter DEPTH      = `PHYS_REG_SZ_R10K,
    parameter N = `N,
    parameter BYPASS_EN  = 0   // 0: Read data will update at positive edge
                               // 1: Read data will update combinationally if
                               //    write to same address
   )(
    input clock, reset, flush, // QUESTION: do we need reset? or should we force write to happen before read at the same addr?
    // retire ??

    // complete (write)
    input logic         [N-1:0] c_en,
        // - Enabled complete lines?
    input PHYS_REG_IDX  [N-1:0] c_ts, // tags
    input DATA          [N-1:0] c_vs, // vals
        // From: complete (EX)

    // issue (read)
    output DATA         [31:0]  state,
        // To: EX
        // - RF state after propagated completes
        // - we just expose the damn thing to EX, who seems to be the only consumer
        //   (insns issued just from RS to EX should read operands same-cycle)
        // - Question: My idea is just to let potentially any FU in EX to index 
        //   into the prf and get the operands it needs. So if there are 32 FUs,
        //   is this like 32 * 2 implicit read ports? (Same implicit read port
        //   concern as cpl_lst's)
    input logic         [N-1:0] s_en,
    input PHYS_REG_IDX  [N-1:0] s_t1s,
    input PHYS_REG_IDX  [N-1:0] s_t2s,
    output DATA        [N-1:0] s_v1s,
    output DATA        [N-1:0] s_v2s
        // To: EX/RS/issuer idk
        // - Explicit read ports for issuing insns to collect operands (alternative to state) 
        // - Have 2N read ports and only allow N issues per cycle. But problem: 
        //   If an insn can issue but is prevented from doing so due to issue
        //   limit, presumably it wont be able to collect operand in that cycle right?
        //   But what happens if some other insn writes to the same operand preg
        //   in the next cycle; it would overwrite the correct value? But then AHA,
        //   THERE CANT BE ANOTHER IDIOT WRITING TO THE SAME PREG CAN IT? So this 
        //   seems to be a non-issue after all. Remember, another insn can only have
        //   same dst in r10k after the one writing to it RETIRES.


    // dispatch ??
);

logic [DEPTH-1:0][WIDTH-1:0]  phys_reg_file;
genvar i;

///////////////////////////////////////////////////////////////////
////////////////////////// Read Logic /////////////////////////////
///////////////////////////////////////////////////////////////////

always_comb begin
    for (int i = 0; i < N; i++) begin
        if (BYPASS_EN != 0) begin : bypass_path
            if (s_en[i] && (s_t1s[i] != `ZERO_REG) && (s_t2s[i] != `ZERO_REG)) begin
                s_v1s[i] = phys_reg_file[s_t1s[i]];
                s_v2s[i] = phys_reg_file[s_t2s[i]];
                for (int j = 0; j < N; j++) begin
                    if (c_en[j] && (s_t1s[i] == c_ts[j])) begin
                        s_v1s[i] = c_vs[j];
                    end
                    // else
                    //     s_v1s[i] = phys_reg_file[s_t1s[i]];
                    if (c_en[j] && (s_t2s[i] == c_ts[j])) begin
                        s_v2s[i] = c_vs[j];
                    end
                    // else
                    //     s_v2s[i] = phys_reg_file[s_t2s[i]];
                end
            end else begin
                s_v1s[i] = '0;
                s_v2s[i] = '0;
            end
        end else begin : non_bypass_path
            s_v1s[i] = s_en[i] ? phys_reg_file[s_t1s[i]] : '0;
            s_v2s[i] = s_en[i] ? phys_reg_file[s_t2s[i]] : '0;
        end
    end
end

 
///////////////////////////////////////////////////////////////////
////////////////////////// Write Logic ////////////////////////////
///////////////////////////////////////////////////////////////////

always_ff @(posedge clock) begin
    if (reset || flush) begin
        phys_reg_file        <= '0;
    end else begin
        for (int k = 0; k < N; k++) begin
            if (c_en[k] && (c_ts[k] != `ZERO_REG)) begin
                phys_reg_file[c_ts[k]] <= c_vs[k];
            end
        end
    end
end


endmodule