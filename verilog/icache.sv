/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  icache.sv                                           //
//                                                                     //
//  Description :  The instruction cache module that reroutes memory   //
//                 accesses to decrease misses.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "verilog/sys_defs.svh"

/**
 * A quick overview of the cache and memory:
 *
 * We've increased the memory latency from 1 cycle to 100ns. which will be
 * multiple cycles for any reasonable processor. Thus, memory can have multiple
 * transactions pending and coordinates them via memory tags (different meaning
 * than cache tags) which represent a transaction it's working on. Memory tags
 * are 4 bits long since 15 mem accesses can be live at one time, and only one
 * access happens per cycle.
 *
 * On a request, memory responds with the tag it will use for that transaction.
 * Then, ceiling(100ns/clock period) cycles later, it will return the data with
 * the corresponding tag. The 0 tag is a sentinel value and unused. It would be
 * very difficult to push your clock period past 100ns/15=6.66ns, so 15 tags is
 * sufficient.
 *
 * This cache coordinates those memory tags to speed up fetching reused data.
 *
 * Note that this cache is blocking, and will wait on one memory request before
 * sending another (unless the input address changes, in which case it abandons
 * that request). Implementing a non-blocking cache can count towards simple
 * feature points, but will require careful management of memory tags.
 */

/* [BUG]
Q: Why does mult_no_lsq.out fail on this default icache implementation?
A: It is because the default icache is BLOCKING, and assumes an implicit contract
with the fetch regarding the PC value.

Specifically, the icache assumes the current index/tag (set by PC_reg) stays constant over
the following interval:
1. Start: when the PC is a miss and you send a request to the mem module
(on the next cycle you receive the txn tag)

2. End: when the data tag returns from mem module, servicing our request.

Since it’s blocking, the icache assumes that the PC hasn't changed by the time
the data comes back — but this is *not guaranteed*, especially if a branch is resolved
in the meantime.

(You can see this clearly: `got_mem_data` only checks the memory tag, and not whether
the *current* PC still corresponds to the PC for which the request was originally made.)

However, this assumption is broken in the presence of branch resolution, which can
update the PC to a new target address while we’re still waiting for memory.

>> This is why I think it's easier we implement a nonblocking cache than try to
craft some hacky custom fix that handles branch resolution.
*/

module icache (
    `ifdef DEBUG
    output DBG_icache dbg,
    `endif 

    input clock,
    input reset,
    input flush,

    // From memory
    input MEM_TAG   Imem2proc_transaction_tag, // Should be zero unless there is a response
    input MEM_BLOCK Imem2proc_data,
    input MEM_TAG   Imem2proc_data_tag,

    // From fetch stage
    input ADDR proc2Icache_addr,

    // To memory
    output MEM_COMMAND proc2Imem_command,
    output ADDR        proc2Imem_addr,

    // To fetch stage
    output MEM_BLOCK Icache_data_out, // Data is mem[proc2Icache_addr]
    output logic     Icache_valid_out // When valid is high
);

    // Note: cache tags, not memory tags
    logic [12-`ICACHE_LINE_BITS:0] current_tag,   last_tag,   write_tag;
    logic [`ICACHE_LINE_BITS -1:0] current_index, last_index, write_index;
    logic                          got_mem_data, flushed;
    MSHR_entry [15:0] MSHR;


    // ---- Cache data ---- //

    ICACHE_TAG [`ICACHE_LINES-1:0] icache_tags;

    //TODO: flush icache of prefetched insns on branch mispredict or keep them in?
    //leaving them in for now, hopefully its not a big deal
    memDP #(
        .WIDTH     ($bits(MEM_BLOCK)),
        .DEPTH     (`ICACHE_LINES),
        .READ_PORTS(1),
        .BYPASS_EN (0))
    icache_mem (
        .clock(clock),
        .reset(reset),
        .re   (1'b1),
        .raddr(current_index),
        .rdata(Icache_data_out),
        .we   (got_mem_data),
        .waddr(write_index),
        .tags(icache_tags),
        .wdata(Imem2proc_data)
    );
    

    // ---- Addresses and final outputs ---- //

    assign {current_tag, current_index} = proc2Icache_addr[15:3];
    assign {write_tag, write_index} = MSHR[Imem2proc_data_tag].valid ? MSHR[Imem2proc_data_tag].addr[15:3] : '1;

    assign Icache_valid_out = icache_tags[current_index].valid &&
                              (icache_tags[current_index].tags == current_tag);

    // ---- Main cache logic ---- //

    // MEM_TAG current_mem_tag; // The current memory tag we might be waiting on
    // logic miss_outstanding; // Whether a miss has received its response tag to wait on

    logic changed_addr, MSHR_update;
    ADDR  PC_prefetch, MSHR_addr;
    // logic update_mem_tag;
    // logic unanswered_miss;

    assign got_mem_data = MSHR[Imem2proc_data_tag].valid && Imem2proc_data != '0;

    assign changed_addr = (current_index != last_index) || (current_tag != last_tag);

    // Set mem tag to zero if we changed_addr, and keep resetting while there is
    // a miss_outstanding. Then set to zero when we got_mem_data.
    // (this relies on Imem2proc_transaction_tag being zero when there is no request)
    // assign update_mem_tag = changed_addr || miss_outstanding || got_mem_data;

    // If we have a new miss or still waiting for the response tag, we might
    // need to wait for the response tag because dcache has priority over icache
    // assign unanswered_miss = changed_addr ? !Icache_valid_out :
                                        //miss_outstanding && (Imem2proc_transaction_tag == 0);

    // Keep sending memory requests until we receive a response tag or change addresses
    assign proc2Imem_command = reset ? MEM_LOAD : (((PC_prefetch - proc2Icache_addr) >= `PREFETCH_CAP && !flushed) ? MEM_NONE : MEM_LOAD);
    assign proc2Imem_addr    = reset ? {proc2Icache_addr[31:3],3'b0} : {PC_prefetch[31:3],3'b0};

    // ---- Cache state registers ---- //

    /*always_comb begin
        if(reset) begin
            MSHR = '0;
        end else begin
            if(Imem2proc_transaction_tag != 0) begin
                MSHR[Imem2proc_transaction_tag].addr    = proc2Imem_addr;
                MSHR[Imem2proc_transaction_tag].valid   = 1;
            end
            if(MSHR[Imem2proc_data_tag].valid) begin
                MSHR[Imem2proc_data_tag].addr   = '0;
                MSHR[Imem2proc_data_tag].valid  = 0;
            end
        end
    end*/

    always_ff @(posedge clock) begin
        if (reset) begin
            last_index       <= -1; // These are -1 to get ball rolling when
            last_tag         <= -1; // reset goes low because addr "changes"
            // current_mem_tag  <= '0;
            // miss_outstanding <= '0;
            icache_tags      <= '0; // Set all cache tags and valid bits to 0
            flushed          <=  0;
            PC_prefetch      <= proc2Icache_addr;
            MSHR <= '0;
            //MSHR_update      <= 1;
            //MSHR_addr        <= '0;
        end else begin
            last_index       <= current_index;
            last_tag         <= current_tag;


            // miss_outstanding <= unanswered_miss;
            // if (update_mem_tag) begin
            //     current_mem_tag <= Imem2proc_transaction_tag;
            // end
            if (got_mem_data) begin // If data came from memory, meaning tag matches
                icache_tags[write_index].tags  <= write_tag;
                icache_tags[write_index].valid <= 1'b1;
            end
            flushed          <= flush; //delay flush by a cycle so you can actually grab new PC from proc2Icache_addr
            if(flushed) begin //if we are branching
                if(Icache_valid_out) begin 
                    PC_prefetch <= proc2Icache_addr + 8; //if we branch to a cache hit, start prefetching a block later so PC_prefetch - PC doesn't go negative and overflow, because PC will be incrementing on the next clock cycle
                end else begin
                    PC_prefetch <= proc2Icache_addr;
                end
            end else begin
                if(proc2Icache_addr > PC_prefetch) begin
                    PC_prefetch <= proc2Icache_addr; //Honestly just make sure PC_prefetch is never less than PC because the overflow from their difference WILL cause problems
                end else if((PC_prefetch - proc2Icache_addr == `PREFETCH_CAP) || (Imem2proc_transaction_tag == 0)) begin
                    PC_prefetch <= PC_prefetch; //don't prefetch too far ahead or you will lose its benefits. Also don't increment when the trans_tag is 0, because the request will not have gone through
                end else begin
                    PC_prefetch <= PC_prefetch + 8;
                end
            end
            //MSHR_update      <= !Icache_valid_out;
            //MSHR_addr        <= (proc2Imem_command == MEM_LOAD) ? proc2Imem_addr : '1;
            if(Imem2proc_transaction_tag != 0) begin
                MSHR[Imem2proc_transaction_tag].addr    <= proc2Imem_addr;
                MSHR[Imem2proc_transaction_tag].valid   <= 1;
            end
            if(MSHR[Imem2proc_data_tag].valid) begin
                MSHR[Imem2proc_data_tag].addr   <= '0;
                MSHR[Imem2proc_data_tag].valid  <= 0;
            end
        end
    end 

    `ifdef DEBUG
    assign dbg = '{
        changed_addr,
        current_tag,   last_tag,   write_tag,
        current_index, last_index, write_index,
        got_mem_data,
        MSHR,
        icache_tags,
        Imem2proc_transaction_tag,
        Imem2proc_data,
        Imem2proc_data_tag,
        proc2Icache_addr,
        proc2Imem_command,
        proc2Imem_addr,
        Icache_data_out,
        Icache_valid_out
    };
    `endif
 
endmodule // icache