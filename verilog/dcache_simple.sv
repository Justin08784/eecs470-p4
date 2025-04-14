`include "sys_defs.svh"

module dcache_simple (
    input logic clock,
    input logic reset,

    // input from memory
    input  MEM_TAG       Dmem2Dcache_transaction_tag,
    input  MEM_BLOCK     Dmem2Dcache_data,
    input  MEM_TAG       Dmem2Dcache_data_tag,

    // input from lsq
    input logic          Dcache_valid_in, 
    // load (executing) store (retired)
    input MEM_COMMAND    proc2Dcache_command, // ✅ Bradley: only one command to dcache, so the load will see the effect of store
    input ADDR           proc2Dcache_addr,
    input MEM_SIZE       proc2Dcache_size,
    input MEM_BLOCK      proc2Dcache_wdata,

    // output to lsq
    output logic         Dcache_valid_out, // load cache hit
    output MEM_BLOCK     Dcache_data_out,
    // output info for load instruction that has the cache miss

    // output to memory 
    output MEM_COMMAND   Dcache2Dmem_command, // ✅ Bradley: IF Dcache and SQ have conflict on memory LET LOAD GO FIRST!!!!!
    output ADDR          Dcache2Dmem_addr,
    output MEM_BLOCK     Dcache2Dmem_wdata,

    // output logic         mem_in_use,
    output logic         dcache_ready
);

    localparam CACHE_LINES  =  `DCACHE_LINES;
    localparam INDEX_BITS = $clog2(CACHE_LINES);
    localparam OFFSET_BITS = 3;
    localparam TAG_WIDTH = 32 - INDEX_BITS - OFFSET_BITS;

    logic we;
    MEM_BLOCK rblock, wblock;

    typedef struct packed {
        logic                 valid;
        logic                 dirty;
        logic [TAG_WIDTH-1:0] tag;
    } DCACHE_TAG;

    DCACHE_TAG [`DCACHE_LINES-1:0] dcache_tags, next_dcache_tags;

    logic [TAG_WIDTH-1:0] current_tag;
    assign current_tag = proc2Dcache_addr[31:32-TAG_WIDTH];
    logic [INDEX_BITS-1:0] current_index;
    assign current_index = proc2Dcache_addr[INDEX_BITS+2:3];
    logic [2:0] byte_addr;
    assign byte_addr = proc2Dcache_addr[2:0];

    logic cache_hit;

        typedef struct packed {
        ADDR                    addr;
        logic [TAG_WIDTH-1:0]   tag;
        logic [INDEX_BITS-1:0]  index;
        logic [2:0]             byte_addr;
        MEM_BLOCK               block;
        MEM_COMMAND             command;
        MEM_SIZE                size;
    } dcache_in;

    typedef struct packed {
        MEM_COMMAND    command;
    } dcache2mem;

    typedef struct packed {
        MEM_TAG   transtag;
    } mem2dcache;

    dcache_in dcache_req, next_dcache_req;
    dcache2mem mem_req, next_mem_req;
    mem2dcache mem_resp, next_mem_resp;

    ADDR raddr, waddr;
    assign raddr = cache_hit? current_index : dcache_req.index;
    assign waddr = cache_hit? current_index : dcache_req.index;

    logic mem_in_use, next_mem_in_use;
    assign dcache_ready = !mem_in_use;

    memDP #(
        .WIDTH     ($bits(MEM_BLOCK)),
        .DEPTH     (`DCACHE_LINES),
        .READ_PORTS(1),
        .BYPASS_EN (0))
    dcache_mem (
        .clock(clock),
        .reset(reset),
        .re   (1'b1),
        .raddr(raddr),
        .rdata(rblock),
        .we   (we),
        .waddr(waddr),
        .wdata(wblock)
    );

    // logic cache_hit;

    typedef enum logic [2:0] {
        IDLE = 3'd0,
        FILL = 3'd1,
        FILL_WAIT = 3'd2,
        RESPOND = 3'd3,
        EVICT = 3'd4
    } STATE;

    STATE state, next_state, prev_state;

    DCACHE_TAG curr_dcache_entry;
    assign curr_dcache_entry = dcache_tags[current_index];

    // typedef struct packed {
    //     ADDR                    addr;
    //     logic [TAG_WIDTH-1:0]   tag;
    //     logic [INDEX_BITS-1:0]  index;
    //     logic [2:0]             byte_addr;
    //     MEM_BLOCK               block;
    //     MEM_COMMAND             command;
    //     MEM_SIZE                size;
    // } dcache_in;

    // typedef struct packed {
    //     MEM_COMMAND    command;
    // } dcache2mem;

    // typedef struct packed {
    //     MEM_TAG   transtag;
    // } mem2dcache;

    // dcache_in dcache_req, next_dcache_req;
    // dcache2mem mem_req, next_mem_req;
    // mem2dcache mem_resp, next_mem_resp;

    // logic [TAG_WIDTH-1:0] pending_tag, next_pending_tag;
    // logic MEM_COMMAND pending_command, next_pending_command;
    // logic ADDR pending_addr, next_pending_addr;



    always_comb begin
        // next_dcache_req = '{
        //     addr: proc2Dcache_addr,
        //     tag:  proc2Dcache_addr[31:32-TAG_WIDTH],
        //     index:  proc2Dcache_addr[INDEX_BITS+2:3],
        //     byte_addr: proc2Dcache_addr[2:0],
        //     block: proc2Dcache_wdata,
        //     command: proc2Dcache_command,
        //     size: proc2Dcache_size
        // }; // move everythin other than dcache_Req to default case

        case (state)
            IDLE: begin
                cache_hit = 0;
                if (!dcache_ready) begin
                    next_dcache_req = '{
                        addr: 32'h0000_0000,
                        tag:  '0,
                        index:  '0,
                        byte_addr: '0,
                        block: '0,
                        command: MEM_NONE,
                        size: '0
                    };
                end else begin
                    next_dcache_req = '{
                        addr: proc2Dcache_addr,
                        tag:  proc2Dcache_addr[31:32-TAG_WIDTH],
                        index:  proc2Dcache_addr[INDEX_BITS+2:3],
                        byte_addr: proc2Dcache_addr[2:0],
                        block: proc2Dcache_wdata,
                        command: proc2Dcache_command,
                        size: proc2Dcache_size
                    };
                end
                if (proc2Dcache_command == MEM_NONE) begin
                    next_mem_in_use = 0;
                    Dcache_valid_out = 0;
                    Dcache_data_out = '0;
                    we = 0;
                    wblock = '0;
                    for (int i = 0; i< CACHE_LINES; i++) begin
                        next_dcache_tags[i] = '{
                            valid : dcache_tags[i].valid,
                            dirty : dcache_tags[i].dirty,
                            tag   : dcache_tags[i].tag
                        };
                    end
                    Dcache2Dmem_addr = '0;
                    Dcache2Dmem_command = MEM_NONE;
                    Dcache2Dmem_wdata = '0;
                    next_state = IDLE;
                    next_mem_req = '{command: MEM_NONE};
                    next_mem_resp = '{transtag : 0};
                end
                else begin
                    if ((curr_dcache_entry.tag == current_tag) && curr_dcache_entry.valid) begin
                        // cache hit : no memory access
                        cache_hit = 1;
                        next_mem_in_use = 0;
                        Dcache2Dmem_addr = '0;
                        Dcache2Dmem_command = MEM_NONE;
                        Dcache2Dmem_wdata = '0;
                        next_state = IDLE;
                        next_mem_req = '{command: MEM_NONE};
                        next_mem_resp = '{transtag : 0};
                        if (proc2Dcache_command == MEM_LOAD) begin // load and hit
                            Dcache_valid_out = 1;
                            Dcache_data_out = rblock;
                            we = 0;
                            wblock = '0;
                            for (int i = 0; i< CACHE_LINES; i++) begin
                                next_dcache_tags[i] = '{
                                    valid : dcache_tags[i].valid,
                                    dirty : dcache_tags[i].dirty,
                                    tag   : dcache_tags[i].tag
                                };
                            end
                        end else if (proc2Dcache_command == MEM_STORE) begin //store and hit
                            case (proc2Dcache_size)
                                BYTE: begin
                                    wblock = rblock;
                                    wblock.byte_level[byte_addr[2:0]] = proc2Dcache_wdata[7:0];
                                end
                                HALF: begin
                                    wblock = rblock;
                                    wblock.half_level[byte_addr[2:1]] = proc2Dcache_wdata[15:0];
                                end
                                WORD:begin
                                    wblock = rblock;
                                    wblock.word_level[byte_addr[2]] = proc2Dcache_wdata[31:0];
                                end
                                DOUBLE: wblock = proc2Dcache_wdata;
                            endcase
                            we = 1;
                            Dcache_valid_out = 0;
                            Dcache_data_out = '0;
                            for (int i = 0; i< CACHE_LINES; i++) begin
                                next_dcache_tags[i] = '{
                                    valid : dcache_tags[i].valid,
                                    dirty : 1'b1,
                                    tag   : dcache_tags[i].tag
                                };
                            end
                        end // state IDLE: cache hit ✅
                    end else begin 
                        cache_hit = 0;
                        next_mem_in_use = 1;
                        Dcache_valid_out = 0;
                        Dcache_data_out = '0;
                        we = 0;
                        wblock = '0;
                        for (int i = 0; i< CACHE_LINES; i++) begin
                            next_dcache_tags[i] = '{
                                valid : dcache_tags[i].valid,
                                dirty : dcache_tags[i].dirty,
                                tag   : dcache_tags[i].tag
                            };
                        end
                        // cache miss
                        if (curr_dcache_entry.dirty) begin // miss and dirty
                            Dcache2Dmem_command = MEM_STORE;
                            Dcache2Dmem_addr = {curr_dcache_entry.tag, current_index, 3'b0};
                            Dcache2Dmem_wdata = rblock;
                            next_mem_req = '{command: MEM_STORE};
                            next_mem_resp = '{transtag : 0};
                            next_state = EVICT;
                            // next_pending_command = MEM_STORE;
                            // next_pending_addr = Dcache2Dmem_addr;
                            
                        end else begin // miss and clean
                            Dcache2Dmem_command = MEM_LOAD;
                            Dcache2Dmem_addr = {proc2Dcache_addr[31:3], 3'b0};
                            Dcache2Dmem_wdata = '0;
                            next_mem_req = '{command: MEM_LOAD};
                            next_mem_resp = '{transtag : 0};
                            next_state = FILL;
                        end
                    end
                end
            end

            FILL: begin
                next_dcache_req = '{
                    addr: dcache_req.addr,
                    tag:  dcache_req.tag,
                    index:  dcache_req.index,
                    byte_addr: dcache_req.byte_addr,
                    block: dcache_req.block,
                    command: dcache_req.command,
                    size: dcache_req.size
                };
                next_mem_in_use = 1;
                Dcache_valid_out = 0;
                Dcache_data_out = '0;
                we = 0;
                wblock = '0;
                Dcache2Dmem_addr = dcache_req.addr;
                Dcache2Dmem_wdata = '0;
                for (int i = 0; i< CACHE_LINES; i++) begin
                    next_dcache_tags[i] = '{
                        valid : dcache_tags[i].valid,
                        dirty : dcache_tags[i].dirty,
                        tag   : dcache_tags[i].tag
                    };
                end
                if (prev_state == EVICT) begin
                    next_mem_req = '{command: MEM_LOAD};
                    next_mem_resp = '{transtag : mem_resp.transtag};
                    next_state = FILL_WAIT;
                    Dcache2Dmem_command = MEM_NONE;

                end else begin
                    if (Dmem2Dcache_transaction_tag != 0) begin
                        next_mem_req = '{command: MEM_LOAD};
                        next_mem_resp = '{transtag : Dmem2Dcache_transaction_tag};
                        next_state = FILL_WAIT;
                        Dcache2Dmem_command = MEM_NONE;
                    end else begin
                        next_mem_req = '{command: MEM_LOAD};
                        next_mem_resp = '{transtag : Dmem2Dcache_transaction_tag};
                        next_state = FILL;
                        Dcache2Dmem_command = MEM_LOAD;
                    end
                end
            end

            FILL_WAIT: begin
                next_dcache_req = '{
                    addr: dcache_req.addr,
                    tag:  dcache_req.tag,
                    index:  dcache_req.index,
                    byte_addr: dcache_req.byte_addr,
                    block: dcache_req.block,
                    command: dcache_req.command,
                    size: dcache_req.size
                };
                // mem_in_use = 1;
                // Dcache_valid_out = 0;
                // Dcache_data_out = '0;
                Dcache2Dmem_command = MEM_NONE;
                Dcache2Dmem_addr = '0;
                Dcache2Dmem_wdata = '0;
                for (int i = 0; i< CACHE_LINES; i++) begin
                    next_dcache_tags[i] = '{
                        valid : dcache_tags[i].valid,
                        dirty : dcache_tags[i].dirty,
                        tag   : dcache_tags[i].tag
                    };
                end
                next_state = IDLE;
                next_mem_in_use = 0;

                if (Dmem2Dcache_data_tag == mem_resp.transtag) begin
                    we = 1;
                    next_mem_req = '{command: MEM_NONE};
                    next_mem_resp = '{transtag : '0};
                    if (dcache_req.command == MEM_LOAD) begin
                        wblock = Dmem2Dcache_data;
                        next_dcache_tags[dcache_req.index].tag = dcache_req.tag;
                        next_dcache_tags[dcache_req.index].valid = 1;
                        next_dcache_tags[dcache_req.index].dirty = 0;
                        Dcache_valid_out = 1;
                        Dcache_data_out = Dmem2Dcache_data;
                        
                    end else if (dcache_req.command == MEM_STORE) begin
                        wblock = Dmem2Dcache_data;
                        case(proc2Dcache_size)
                            BYTE: wblock.byte_level[dcache_req.byte_addr[2:0]] = dcache_req.block[7:0];
                            HALF: wblock.half_level[dcache_req.byte_addr[2:1]] = dcache_req.block[15:0];
                            WORD: wblock.word_level[dcache_req.byte_addr[2]] = dcache_req.block[31:0];
                            DOUBLE: wblock = Dmem2Dcache_data;
                        endcase
                        next_dcache_tags[dcache_req.index].tag = dcache_req.tag;
                        next_dcache_tags[dcache_req.index].valid = 1;
                        next_dcache_tags[dcache_req.index].dirty = 1;
                        Dcache_valid_out = 0;
                        Dcache_data_out = '0;
                    end
                end else begin
                    next_mem_req = '{command: mem_req.command};
                    next_mem_resp = '{transtag : mem_resp.transtag};
                    we = 0;
                    wblock = '0;
                    Dcache_valid_out = 0;
                    Dcache_data_out = '0;
                    next_state = FILL_WAIT;
                    next_mem_in_use = 1;
                    
                end
            end

            EVICT: begin
                next_dcache_req = '{
                    addr: dcache_req.addr,
                    tag:  dcache_req.tag,
                    index:  dcache_req.index,
                    byte_addr: dcache_req.byte_addr,
                    block: dcache_req.block,
                    command: dcache_req.command,
                    size: dcache_req.size
                };
                next_mem_in_use = 1;
                Dcache_valid_out = 0;
                Dcache_data_out = '0;
                // we = 0;
                // wblock = '0;
                for (int i = 0; i< CACHE_LINES; i++) begin
                    next_dcache_tags[i] = '{
                        valid : dcache_tags[i].valid,
                        dirty : dcache_tags[i].dirty,
                        tag   : dcache_tags[i].tag
                    };
                end
                if (Dmem2Dcache_transaction_tag != 0) begin
                    Dcache2Dmem_command = MEM_LOAD;
                    Dcache2Dmem_addr = {dcache_req.addr[31:3], 3'b0};
                    Dcache2Dmem_wdata = '0;
                    next_state = FILL; 
                    next_mem_req = '{command: MEM_LOAD};
                    next_mem_resp = '{transtag: Dmem2Dcache_transaction_tag};
                    next_dcache_tags[dcache_req.index].tag = 0;
                    next_dcache_tags[dcache_req.index].valid = 0;
                    next_dcache_tags[dcache_req.index].dirty = 0;
                    we = 1;
                    wblock = '0;
                end else begin
                    Dcache2Dmem_command = MEM_STORE;
                    Dcache2Dmem_addr = {dcache_tags[dcache_req.index].tag, dcache_req.index, 3'b0};
                    Dcache2Dmem_wdata = rblock;
                    next_state = EVICT; 
                    next_mem_req = '{command: MEM_STORE};
                    next_mem_resp = '{transtag: '0};
                    next_dcache_tags[dcache_req.index].tag = dcache_req.tag;
                    next_dcache_tags[dcache_req.index].valid = dcache_req.tag;
                    next_dcache_tags[dcache_req.index].dirty = dcache_req.tag;
                    we = 0;
                    wblock = '0;
                end
            end

            default: begin
                next_dcache_req = '{
                    addr: proc2Dcache_addr,
                    tag:  proc2Dcache_addr[31:32-TAG_WIDTH],
                    index:  proc2Dcache_addr[INDEX_BITS+2:3],
                    byte_addr: proc2Dcache_addr[2:0],
                    block: proc2Dcache_wdata,
                    command: proc2Dcache_command,
                    size: proc2Dcache_size
                };
                for (int i = 0; i< CACHE_LINES; i++) begin
                    next_dcache_tags[i].valid = 0;
                    next_dcache_tags[i].dirty = 0;
                    next_dcache_tags[i].tag = '0;
                end 
                next_state = IDLE;
                next_mem_req = '{command: MEM_NONE};
                next_mem_resp = '{transtag : '0};
                Dcache_valid_out = 0;
                Dcache_data_out = '0;
                Dcache2Dmem_addr = '0;
                Dcache2Dmem_command = MEM_NONE;
                Dcache2Dmem_wdata = '0;
                we = 0;
                wblock = '0;
                next_mem_in_use = 0;
            end
        endcase
    end


    always_ff @(posedge clock) begin
        if (reset) begin
            prev_state <= IDLE;
            state <= IDLE;
            mem_in_use = 0;
            for (int i = 0; i< CACHE_LINES; i++) begin
                dcache_tags[i].valid <= 0;
                dcache_tags[i].dirty <= 0;
                dcache_tags[i].tag <= '0;
            end
            dcache_req <= '{
                addr: '0,
                tag:  '0,
                index:  '0,
                byte_addr: '0,
                block: '0,
                command: '0,
                size: '0
            };
            mem_req <= '{command: MEM_NONE};
            mem_resp <= {transtag : '0};
        end else begin
            mem_in_use <= next_mem_in_use;
            prev_state <= state;
            state <= next_state;
            for (int i = 0; i< CACHE_LINES; i++) begin
                dcache_tags[i] <= next_dcache_tags[i];
                // dcache_tags[i].dirty = next_dcache_tags[i].dirty;
                // dcache_tags[i].tag = next_dcache_tags[i].tag;
            end
            dcache_req <= next_dcache_req;
            mem_req <= next_mem_req;
            mem_resp <= next_mem_resp;
        end
    end
    




endmodule;