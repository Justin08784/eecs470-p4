`include "sys_defs.svh"

/*
TODO: I think there might need to be a retire module that interfaces with
both ROB and BTQ. Like if a retiring branch insn is mispredicted,
the rob insns after it should not be committed!

Maybe something that handles both rollback and retire?
*/

/* Branch target queue */
module btq #(
    parameter BTQ_SZ = `BTQ_SZ,  // num elements
    parameter N=`N
) (
    input clock, reset, flush,
    `ifdef DEBUG
    output BTQ_ENTRY [BTQ_SZ-1:0]   state_dbg,
    `endif 

    // retire
    input  retire2btq       r_in,
    output btq2retire       r_out,

    // complete (write)
    input  execute2complete c_in, // TODO: handling from EX

    // dispatch (write)
    input  dispatch2btq d_in,
    output btq2dispatch d_out
);
    localparam NUM_DPORTS = N; // dispatch ports (in-order)
    localparam NUM_RPORTS = N; // retire ports (in-order)
    localparam NUM_CPORTS = N; // complete ports (*OUT-OF-ORDER*)

    BTQ_ENTRY [BTQ_SZ-1:0]      state;
    logic [$clog2(BTQ_SZ)-1:0]  head;
    logic [$clog2(BTQ_SZ)-1:0]  tail;
    logic [$clog2(BTQ_SZ):0]    used;

    logic [$clog2(BTQ_SZ):0]    free;
    assign free         = BTQ_SZ - used;
    assign state_dbg    = state;

    logic [$clog2(NUM_DPORTS):0]    wr_cnt;
    logic [$clog2(NUM_RPORTS):0]    rd_cnt;
    assign wr_cnt = d_in.en_cnt;
    assign rd_cnt = r_in.rd_cnt;

    logic [NUM_RPORTS-1:0][$clog2(BTQ_SZ)-1:0] r_idxs;
    logic [NUM_DPORTS-1:0][$clog2(BTQ_SZ)-1:0] d_idxs;
    always_comb begin
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_idxs[i] = (head + i) % BTQ_SZ;
        for (int unsigned i = 0; i < NUM_DPORTS; ++i)
            d_idxs[i] = (tail + i) % BTQ_SZ;

        // handle retire (outs)
        r_out = '0;
        r_out.used_scnt = `MIN(used, NUM_RPORTS);
        for (int unsigned i = 0; i < NUM_RPORTS; ++i)
            r_out.dat[i] = state[r_idxs[i]];

        // handle dispatch (outs)
        /*
        TODO: This tradeoff needs consideration for performance
        Option 1: 
        d_out.btq_rdy_scnt = `MIN(free + rd_cnt, NUM_DPORTS);
        + avoids dispatch stalls when BTQ is full if N branches retire per cycle
        - longer combinational delay due to dependency on rd_cnt

        Option 2: 
        d_out.btq_rdy_scnt = `MIN(free, NUM_DPORTS);
        (opposite of above points)
        */
        d_out = '{
            btq_rdy_scnt : `MIN(free, NUM_DPORTS),
            btq_idxs     : d_idxs
        };
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            used    <= 0;
            head    <= 0;
            tail    <= 0;
            state   <= '0;
        end else begin
            if (wr_cnt > free)
                $error("BTQ overflow!");
            if (rd_cnt > used)
                $error("BTQ underflow!");
            used    <= used + wr_cnt - rd_cnt;
            head    <= (head + rd_cnt) % BTQ_SZ;
            tail    <= (tail + wr_cnt) % BTQ_SZ;

            // handle complete (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_CPORTS; ++i) begin
                if (!c_in.c_en[i] || !c_in.is_branch[i])
                    continue;
                cur_idx = c_in.btq_idxs[i];

                state[cur_idx].tgt  <= c_in.c_data[i];
                state[cur_idx].take <= c_in.take[i];
            end

            // handle dispatch (ins)
            for (int unsigned i = 0, int cur_idx = 0; i < NUM_DPORTS; ++i) begin
                if (i >= wr_cnt)
                    continue;
                cur_idx = d_idxs[i];
                state[cur_idx] <= '{
                    tgt     : '0,
                    NPC     : d_in.NPC[i],
                    // TODO: pred and take need to be set by fetch! I think?
                    pred    : '0,
                    take    : '0
                };
            end
        end
    end

    `ifndef SYNTH
    always_ff @(posedge clock) begin
        if (!reset) begin
            $display("  %3d | BTQ >>", $time);
            for (int i = 0; i < `BTQ_SZ; ++i) begin
                $display("BTQ [%0d]: tgt: %x, NPC: %x, pred: %b, take: %b%s", 
                    i,
                    state[i].tgt,
                    state[i].NPC,
                    state[i].pred,
                    state[i].take,
                    (i == head && head == tail) 
                        ? " << h/t"
                        : (i == head) 
                            ? " << h" 
                            : (i == tail)
                                ? " << t"
                                : ""
                );
            end

            for (int i = 0; i < `N; ++i) begin
                $display("c_in[%0d]: c_en: %b, is_branch: %b, c_btq_idxs: %d, take: %b", 
                    i,
                    c_in.c_en[i],
                    c_in.is_branch[i],
                    c_in.btq_idxs[i],
                    c_in.take[i]
                );
            end
            $display("r_in: rd_cnt %d", r_in.rd_cnt);
            $display("r_out: used_scnt: %0d r_idxs: %0d %0d", r_out.used_scnt, r_idxs[0], r_idxs[1]);
            for (int i = 0; i < `N; ++i) begin
                $display("r_out[%d]: tgt: %x, NPC: %x, pred: %b, take: %b", 
                    i,
                    r_out.dat[i].tgt,
                    r_out.dat[i].NPC,
                    r_out.dat[i].pred,
                    r_out.dat[i].take
                );
            end
            $display("  %3d | BTQ <<", $time);
        end
    end
    `endif // SYNTH

endmodule
