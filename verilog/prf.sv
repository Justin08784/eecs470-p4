`include "sys_defs.svh"

module prf #(
    parameter WIDTH = $bits(DATA),
    parameter DEPTH = PHYS_REG_SZ_R10K,
    parameter N     = 2,
    parameter NUM_RPORTS = NUM_FU_TOTAL
) (
`ifdef DEBUG
    output logic [DEPTH-1:0][WIDTH-1:0] dbg_file,
`endif
    input clock, //reset, flush, // QUESTION: do we need reset? or should we force write to happen before read at the same addr?
`ifdef FORMAL
    input reset,
`endif

    // complete (write)
    input execute2complete_dat cdat_in,

    // issue (read)
    //output DATA         [31:0]  state,
        // To: EX
        // - RF state after propagated completes
        // - we just expose the damn thing to EX, who seems to be the only consumer
        //   (insns issued just from RS to EX should read operands same-cycle)
        // - Question: My idea is just to let potentially any FU in EX to index 
        //   into the prf and get the operands it needs. So if there are 32 FUs,
        //   is this like 32 * 2 implicit read ports? (Same implicit read port
        //   concern as cpl_lst's)
    input logic        [NUM_RPORTS-1:0] s_en1s,
    input PHYS_REG_IDX [NUM_RPORTS-1:0] s_t1s,
    input logic        [NUM_RPORTS-1:0] s_en2s,
    input PHYS_REG_IDX [NUM_RPORTS-1:0] s_t2s,
    output DATA        [NUM_RPORTS-1:0] s_v1s,
    output DATA        [NUM_RPORTS-1:0] s_v2s
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
);
    logic [DEPTH-1:0][WIDTH-1:0] file;

    // Read ports
    always_comb begin
        s_v1s = '0;
        s_v2s = '0;
        for (int i = 0; i < NUM_RPORTS; i++) begin
            
            // TODO: enable should be more granular–– per t1/t2. Some insns only need to read 1 value.
            if      (cdat_in.en[0] && (cdat_in.ts[0] == s_t1s[i]))
                s_v1s[i] = cdat_in.data[0]; // internal forwarding
            else if (cdat_in.en[1] && (cdat_in.ts[1] == s_t1s[i]))
                s_v1s[i] = cdat_in.data[1]; // internal forwarding
            else
                s_v1s[i] = file[s_t1s[i]];

            if      (cdat_in.en[0] && (cdat_in.ts[0] == s_t2s[i]))
                s_v2s[i] = cdat_in.data[0]; // internal forwarding
            else if (cdat_in.en[1] && (cdat_in.ts[1] == s_t2s[i]))
                s_v2s[i] = cdat_in.data[1]; // internal forwarding 
            else
                s_v2s[i] = file[s_t2s[i]];
            
        end
    end

    // Write port
    always_ff @(posedge clock) begin
        foreach (cdat_in.en[i]) begin
            if (cdat_in.en[i])
                file[cdat_in.ts[i]] <= cdat_in.data[i];
        end

        file[`ZERO_PHYS_REG] <= '0; // pin zero reg to 0
    end


`ifdef DEBUG
    assign dbg_file = file;
    task print_prf;
        $display("TODO: impl print_prf");
    endtask
`endif

`ifdef FORMAL
    always_ff @(posedge clock) begin
        for (int c = 0; c < N; ++c)
            assert(reset | ~cdat_in.en[c] | ~(cdat_in.ts[c] == `ZERO_PHYS_REG & cdat_in.data[c] != '0)) else $fatal;
        /*
        cdat broadcast invariant: a write to the zero register must never write a nonzero value

        Important because PRF bypass and CDB bypass both forward the writer's value to the reader
        if tags match **even if** the destination tag is 0. Pinning `ZERO_PHYS_REG to 0 is insufficient
        because on cdat tag match data will be supplied via the cdat bypass.
        */
    end
`endif

endmodule