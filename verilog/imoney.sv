/////////////////////////////////////////////////////////////////////////
//                                                                     //
//   Modulename :  icache.sv                                           //
//                                                                     //
//  Description :  The instruction cache module that reroutes memory   //
//                 accesses to decrease misses.                        //
//                                                                     //
/////////////////////////////////////////////////////////////////////////

`include "verilog/sys_defs.svh"

typedef struct packed {
    logic [NUM_CACHE_LINES-1:0] vld;
    TAG   [NUM_CACHE_LINES-1:0] tag;
} CACHE_HEADER;

typedef struct packed {
    logic vld;
    ADDR  addr;
} ICACHE_MSHR;


module refill_engine (
    input reset,
    input clock,
    // expose mshr state
    output MSHR_ENTRY   mshr_out,

    input  MSHR_SND     snd_in,

    input  MEM_TAG      mem_in_transaction_tag,
    input  MEM_BLOCK    mem_in_data,
    input  MEM_TAG      mem_in_data_tag,

    output MEM_COMMAND  mem_out_command,
    output ADDR         mem_out_addr,
    output MEM_BLOCK    mem_out_data
);
    MSHR_ENTRY [15:0] mshr, mshr_n;
    assign mshr_out = mshr;

    always_comb begin
        mshr_n = mshr;
        mem_out_command = '0;
        mem_out_addr    = '0;
        mem_out_data    = '0;

        case(mshr.status)
        S_IDLE: begin
            case ({snd_in.op, snd_in.en})
            {OP_LOAD_MISS, `TRUE}: begin
                mshr_n = '{
                    status   : S_NTAG,
                    wr_mem   : snd_in.wr_mem,
                    miss_tag : '0,
                    addr     : snd_in.addr,
                    mem_data : snd_in.mem_data,
                    mem_size : snd_in.mem_size
                };
            end
            {OP_STOR_MISS, `TRUE}: begin
                mshr_n = '{
                    status   : S_NTAG,
                    wr_mem   : snd_in.wr_mem,
                    miss_tag : '0,
                    addr     : snd_in.addr,
                    mem_data : snd_in.mem_data,
                    mem_size : snd_in.mem_size
                };
            end
            endcase
        end

        S_NTAG: begin
            if (mshr.miss_tag == 0) begin
                mem_out_addr    = dw_align(mshr.addr);
                mem_out_data    = mshr.mem_data;
                mem_out_command = mshr.wr_mem ? MEM_STORE : MEM_LOAD;
            end

            if (mshr.wr_mem  && mem_in_transaction_tag != 0) begin
                mshr_n.miss_tag = mem_in_transaction_tag;
                mshr_n.status   = S_IDLE;
            end else if 
               (!mshr.wr_mem && mem_in_transaction_tag != 0) begin
                mshr_n.miss_tag = mem_in_transaction_tag;
                mshr_n.status   = S_WAIT;
            end
        end

        S_WAIT: begin
            if (mem_in_data_tag != 0
                && mem_in_data_tag == mshr.miss_tag) begin
                mshr_n.status   = S_FILL;
                mshr_n.mem_data = mem_in_data;
            end
        end

        S_FILL: begin
            case ({snd_in.op, snd_in.en})
            {OP_FILL_EVICT, `TRUE}: begin
                mshr_n = '{
                    status   : S_NTAG,
                    wr_mem   : snd_in.wr_mem,
                    miss_tag : '0,
                    addr     : snd_in.addr,
                    mem_data : snd_in.mem_data,
                    mem_size : snd_in.mem_size
                };
            end
            {OP_FILL_NO_EVICT, `TRUE}: begin
                mshr_n        = '0;
                mshr_n.status = S_IDLE;
            end
            default:;
            endcase
        end
        endcase
    end

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            mshr <= '0;
        end else begin
            mshr <= mshr_n;
        end
    end
endmodule

module imoney (
    `ifdef DEBUG
    output DBG_icache dbg,
    `endif 

    input clock,
    input reset,
    input flush,

    // From memory
    input MEM_TAG       mem_in_txn_tag, // Should be zero unless there is a response
    input MEM_BLOCK     mem_in_data,
    input MEM_TAG       mem_in_data_tag,

    // From fetch stage
    input ADDR          PC,

    // To memory
    output MEM_COMMAND  mem_out_command,
    output ADDR         mem_out_addr,

    // To fetch stage
    output MEM_BLOCK    dat, // Data is mem[PC_reg]
    output logic        vld // When valid is high
);
    ADDR PC_pref, PC_pref_n;
    MSHR_ENTRY [15:0] mshr, mshr_n;

    always_ff @(posedge clock) begin
        if (reset || flush) begin
            mshr    <= '0;
            PC_pref <= PC;
        end else begin
            mshr    <= mshr_n;
            PC_pref <= PC_pref_n;
        end
    end

    refill_engine dec_refill (
        .reset  (reset),
        .clock  (clock),

        .mshr_out(mshr),
        .snd_in  (mshr_snds[gnt_reqr]),

        .mem_in_transaction_tag (mem_in_transaction_tag),
        .mem_in_data            (mem_in_data),
        .mem_in_data_tag        (mem_in_data_tag),

        .mem_out_command(mem_out_command),
        .mem_out_addr   (mem_out_addr),
        .mem_out_data   (mem_out_data)
    );

    logic   ren,  wen;
    WAY     rway, wway;
    MEM_BLOCK rdat, wdat;
    logic [`ICACHE_LINES-1:0][$bits(MEM_BLOCK)-1:0] dbg_memDP;
    memDP #(
        .WIDTH     ($bits(MEM_BLOCK)),
        .DEPTH     (`ICACHE_LINES),
        .READ_PORTS(1),
        .BYPASS_EN (0)
    ) state (
        .dbg  (dbg_memDP),
        .clock(clock),
        .reset(reset),
        .re   (ren ),
        .raddr(rway),
        .rdata(rdat),
        .we   (wen ),
        .waddr(wway),
        .wdata(wdat)
    );




 
endmodule // icache