`include "sys_defs.svh"

// TODO:
// 📌 multiple read port 
// 📌 cache miss data back to load ✅
// 📌 byte/word/half level 
// 📌 synthesis 
// 📌 test with mem 
// (Maybe) load and store command seperately?

// currently every load instruction that goes to the memory load the whole memblock. memsize is only used in rdata_array to output the size of desired data
// store instruction also write the entire memblock 
// (should i change this?)

module dcache #(
  parameter ASSOCIATIVITY = 4,
  parameter NUM_MSHRS = 16,
  parameter NUM_READ = 2
)(
  input logic clock,
  input logic reset,

  // input from memory
  input  MEM_TAG       Dmem2Dcache_transaction_tag,
  input  MEM_BLOCK     Dmem2Dcache_data,
  input  MEM_TAG       Dmem2Dcache_data_tag,


  // input from lsq
  input logic [NUM_READ-1:0]        Dcache_valid_in, 
  input MEM_COMMAND                 proc2Dcache_command, // 🛑 Bradley: only one command to dcache, so the load will see the effect fo store
  input ADDR [NUM_READ-1:0]         proc2Dcache_raddr,
  input MEM_BLOCK [NUM_READ-1:0]    proc2Dcache_rdata,

  input ADDR          proc2Dcache_waddr,
  input MEM_BLOCK     proc2Dcache_wdata,

  input MEM_SIZE [NUM_READ-1:0]     proc2Dcache_size, // only for load, store always write the whole block (might need to change)

  // output to lsq
  output logic [NUM_READ-1:0]        Dcache_valid_out, // indicates cache hit
  output MEM_BLOCK [NUM_READ-1:0]    Dcache_data_out,
  output struct packed {
    ADDR addr;
    MEM_BLOCK data;
    MEM_SIZE size;
  } Dcache_miss_out, 

  // output to memory 
  output MEM_COMMAND   Dcache2Dmem_command, // 🛑Bradley: IF Dcache and SQ have conflict on memory LET LOAD GO FIRST!!!!!
  output ADDR          Dcache2Dmem_addr
  // output MEM_BLOCK     Dcache2Dmem_wdata // store to mem handled by sq
);


  localparam NUM_CACHE_LINES  =  `DCACHE_LINES;
  localparam NUM_SETS         =  NUM_CACHE_LINES / ASSOCIATIVITY;
  localparam SET_INDEX_BITS   =  $clog2(NUM_SETS);
  localparam OFFSET_BITS      =  3; // TODO: load and store for differnet mem size (rn its only double)
  localparam TAG_WIDTH        =  32 - SET_INDEX_BITS - OFFSET_BITS;
  localparam WAY_INDEX_BITS   =  $clog2(ASSOCIATIVITY);
  localparam MSHR_INDEX_BITS  =  $clog2(NUM_MSHRS);

  typedef struct packed {
    logic                 valid;
    logic [TAG_WIDTH-1:0] tag;
  } DCACHE_ENTRY;

  typedef struct packed {
    logic allocated;
    //logic MEM_COMMAND ;//?
    ADDR addr; // cache line addr
    MEM_TAG trans_tag; // ?
    MEM_BLOCK mem_data; // ?
    MEM_SIZE mem_size;
    logic ready;
  } MSHR_ENTRY;

  DCACHE_ENTRY dcache [NUM_SETS][ASSOCIATIVITY];
  MSHR_ENTRY mshr [NUM_MSHRS];
  logic [ASSOCIATIVITY-1:0][WAY_INDEX_BITS-1:0] lru [NUM_SETS];

  logic      [NUM_READ-1:0] re_array    [ASSOCIATIVITY];
  ADDR       [NUM_READ-1:0] raddr_array [ASSOCIATIVITY];
  MEM_BLOCK  [NUM_READ-1:0] rdata_array [ASSOCIATIVITY];
  logic      we_array    [ASSOCIATIVITY];
  ADDR       waddr_array [ASSOCIATIVITY];
  MEM_BLOCK  wdata_array [ASSOCIATIVITY];

  //logic [WAY_INDEX_BITS-1:0] accessed_way;

  genvar w;
  generate
    for (w=0; w<ASSOCIATIVITY; w++) begin : dcache_mem_block
      memDP #(
          .WIDTH     ($bits(MEM_BLOCK)),
          .DEPTH     (NUM_SETS),
          .READ_PORTS(NUM_READ),
          .BYPASS_EN (0))
      dcache_mem (
          .clock(clock),
          .reset(reset),
          .re   (re_array[w]),
          .raddr(raddr_array[w]),
          .rdata(rdata_array[w]),
          .we   (we_array[w]),
          .waddr(waddr_array[w]),
          .wdata(wdata_array[w])
      );
    end
  endgenerate


  logic [NUM_READ-1:0][TAG_WIDTH-1:0] current_read_tag;
  logic [NUM_READ-1:0][SET_INDEX_BITS-1:0] current_read_set_index;
  logic [TAG_WIDTH-1:0] current_write_tag;
  logic [SET_INDEX_BITS-1:0] current_write_set_index;

  logic [NUM_READ-1:0] cache_hit; 
  logic [NUM_READ-1:0][WAY_INDEX_BITS-1:0] hit_way; 
  logic  read_operation; 
  logic  write_store;
  logic  write_mshr;

  logic [WAY_INDEX_BITS-1:0] lru_way[NUM_SETS]; 
  logic [ASSOCIATIVITY-1:0][WAY_INDEX_BITS-1:0] lru_updates [NUM_SETS];

  ADDR cachemiss_addr;
  MEM_SIZE cachemiss_memsize;
  //logic write_source;

  //logic [1:0] write_source; // write from store (1) or mshr(2)? 0 not writing
  logic re_update_enable;

  logic wr_update_mshr;

  

  
  
  always_comb begin
    read_operation = 0;
    for (int r = 0; r< NUM_READ; r++) begin
      cache_hit[r] = 0;
      hit_way[r] = '0;
      current_read_tag[r] = proc2Dcache_raddr[r][31:32-TAG_WIDTH];
      current_read_set_index[r] = proc2Dcache_raddr[r][SET_INDEX_BITS+2:3];
      // current_write_tag = proc2Dcache_addr[31:32-TAG_WIDTH];
      // current_write_set_index = proc2Dcache_addr[SET_INDEX_BITS+2:3];
      // write_store = 0;
      // write_mshr = 0;
      // write_source = `DCACHE_WRITE_SOURCE_STORE;
      //initialize read
      for (int i=0; i<ASSOCIATIVITY; i++) begin
        // for (int r=0; r<NUM_READ; r++) begin
          re_array[i][r] = 0;
          raddr_array[i][r] = '0;
        // end
      end

      if (proc2Dcache_command == MEM_LOAD) begin
        for (int i=0; i<ASSOCIATIVITY; i++) begin
          if (dcache[current_read_set_index[r]][i].valid && dcache[current_read_set_index[r]][i].tag == current_read_tag[r]) begin // hit
            cache_hit[r] = 1;
            hit_way[r] = i;
          end
        end
        if (cache_hit[r]) begin
          read_operation = 1;
          re_array[hit_way[r]][r] = cache_hit[r];
          raddr_array[hit_way[r]][r] = current_read_set_index[r];
        end 
      end
      // if (proc2Dcache_command == MEM_STORE) begin
      //   write_store = 1;
      //   // write_source = `DCACHE_WRITE_SOURCE_STORE;
      // end else begin
      //   for (int m=0; m<NUM_MSHRS; m++) begin
      //     if (mshr[m].ready) begin
      //       current_write_tag = mshr[m].addr[31:32-TAG_WIDTH];
      //       current_write_set_index = mshr[m].addr[SET_INDEX_BITS+2:3];
      //       write_mshr = 1;
      //     end
      //   end

      // end
    end
  end



  always_comb begin
    current_write_tag = proc2Dcache_waddr[31:32-TAG_WIDTH];
    current_write_set_index = proc2Dcache_waddr[SET_INDEX_BITS+2:3];
    write_store = 0;
    write_mshr = 0;
    if (proc2Dcache_command == MEM_STORE) begin
      write_store = 1;
      // write_source = `DCACHE_WRITE_SOURCE_STORE;
    end else begin
      for (int m=0; m<NUM_MSHRS; m++) begin
        if (mshr[m].ready) begin
          current_write_tag = mshr[m].addr[31:32-TAG_WIDTH];
          current_write_set_index = mshr[m].addr[SET_INDEX_BITS+2:3];
          write_mshr = 1;
        end
      end
    end
  end






  logic mshr_complete [NUM_MSHRS];
  always_comb begin
    //initialize write array
    for (int i=0; i<ASSOCIATIVITY; i++) begin
      we_array[i] = 0;
      waddr_array[i] = '0;
      wdata_array[i] = '0;
    end
    Dcache_miss_out.addr = '0;
    Dcache_miss_out.data = '0;
    Dcache_miss_out.size = '0;

    for (int m = 0; m < NUM_MSHRS; m++) begin
      mshr_complete[m] = 0;
    end
    if (write_store == 1) begin
      //if (proc2Dcache_command == MEM_STORE) begin  // 
        we_array[lru_updates[current_write_set_index][3]] = proc2Dcache_command == MEM_STORE;
        waddr_array[lru_updates[current_write_set_index][3]] = current_write_set_index;
        wdata_array[lru_updates[current_write_set_index][3]] = proc2Dcache_wdata;    // BIT MASK ❗️
    end else if (write_mshr == 1) begin
      for (int m=0; m<NUM_MSHRS; m++) begin
        //if (wr_update_mshr) begin
          if (mshr[m].ready) begin
            mshr_complete[m] = 1;
            //if (wr_update_mshr) begin
              we_array[lru_updates[current_write_set_index][3]] = mshr[m].ready;
              waddr_array[lru_updates[current_write_set_index][3]] = current_write_set_index;
              wdata_array[lru_updates[current_write_set_index][3]] = mshr[m].mem_data;
              //mshr_complete[m] = 1;
              Dcache_miss_out.addr = mshr[m].addr;
              Dcache_miss_out.size = mshr[m].mem_size;
              case (Dcache_miss_out.size)
                BYTE:   Dcache_miss_out.data = {56'b0, mshr[m].mem_data.byte_level[Dcache_miss_out.addr[2:0]]};
                HALF:   Dcache_miss_out.data = {48'b0, mshr[m].mem_data.half_level[Dcache_miss_out.addr[2:1]]};
                WORD:   Dcache_miss_out.data = {32'b0, mshr[m].mem_data.word_level[Dcache_miss_out.addr[2]]};
                DOUBLE: Dcache_miss_out.data = mshr[m].mem_data;
              endcase
              //Dcache_miss_out.data = mshr[m].mem_data; //❗️MEMSIZE

            //end
          end
      end
    end
  end

  // logic [MSHR_INDEX_BITS-1:0] num_mshr_available; // ❗️ STALL LOAD INSTRUCTIONS WHEN NUM_MSHR_AVALABLE < NUM READS!!!
  // logic [MSHR_INDEX_BITS-1:0] free_mshr_idx [NUM_READ];
  // always_comb begin
  //   num_mshr_available = NUM_MSHRS;
  //   for (int m=NUM_MSHRS-1; m>=0; m--) begin
  //     if (mshr[m].allocated == 0) begin
  //       free_mshr_idx = m;
  //     end else begin
  //       num_mshr_available = num_mshr_available - 1;
  //     end
  //   end
  // end

  logic[2:0] byte_addr;
  logic[$clog2(NUM_READ)-1:0] cache_miss_rport;

  always_comb begin
    Dcache_valid_out = 0;
    Dcache_data_out = '0;
    Dcache2Dmem_command = MEM_NONE;
    // Dcache2Dmem_addr = '0;
    if (proc2Dcache_command == MEM_LOAD) begin
      for (int r=0; r<NUM_READ; r++) begin
        if (cache_hit[r]) begin
          Dcache_valid_out[r] = cache_hit[r];
          byte_addr = raddr_array[r][2:0];
          case (proc2Dcache_size[r])
              BYTE:   Dcache_data_out[r] = {56'b0, rdata_array[hit_way[r]][r].byte_level[byte_addr[2:0]]};
              HALF:   Dcache_data_out[r] = {48'b0, rdata_array[hit_way[r]][r].half_level[byte_addr[2:1]]};
              WORD:   Dcache_data_out[r] = {32'b0, rdata_array[hit_way[r]][r].word_level[byte_addr[2]]};
              DOUBLE: Dcache_data_out[r] = rdata_array[hit_way[r]][r];
          endcase

          //Dcache_data_out[r] = rdata_array[hit_way[r]][r];   // BIT MASK ❗️
        end else begin
          Dcache2Dmem_command = MEM_LOAD;
          Dcache2Dmem_addr = {proc2Dcache_raddr[r][31:3], 3'b0};
          cache_miss_rport = r;
        end
      end
    end
  end




  // logic [ASSOCIATIVITY-1:0][WAY_INDEX_BITS-1:0] lru_updates [NUM_SETS];
  logic lru_update_enable;
  logic [ASSOCIATIVITY-1:0][WAY_INDEX_BITS-1:0] lru_updates_temp; 

  always_comb begin
    for (int i=0; i< NUM_SETS; i++) begin
      if (lru_update_enable) begin
        
        if (read_operation && !(write_store || write_mshr)) begin
          for (int r=0; r<NUM_READ; r++) begin
            if (i == current_read_set_index[r]) begin
              lru_updates[i] = update_lru(lru[current_read_set_index[r]], hit_way);
              
            end else begin
              lru_updates[i] = lru[i];
            end
          end 
        end else if ((write_store || write_mshr) && !read_operation) begin
          if (i == current_write_set_index) begin
            lru_updates[i] = update_lru(lru[current_write_set_index], lru_way[current_write_set_index]);
            break;
          end else begin
            lru_updates[i] = lru[i];
          end
        end else if ((write_store || write_mshr) && read_operation) begin
          for (int r=0; r<NUM_READ; r++) begin
            if ((i == current_read_set_index[r]) && (current_write_set_index == current_read_set_index[r])) begin
              lru_updates[i] = update_lru(update_lru(lru[current_read_set_index[r]], hit_way), lru_way[current_write_set_index]);
              break;
            end else if (i == current_read_set_index[r]) begin
              lru_updates[i] = update_lru(lru[current_read_set_index[r]], hit_way);
              break;
            end else if (i == current_write_set_index) begin
              lru_updates[i] = update_lru(lru[current_write_set_index], lru_way[current_write_set_index]);
              break;
            end else begin
              lru_updates[i] = lru[i];
            end
          end
        end 
      end else begin
        lru_updates[i] = lru[i];
      end
    end
  end










  MSHR_ENTRY mshr_updates [NUM_MSHRS];
  always_comb begin
    for (int m=0; m<NUM_MSHRS; m++) begin
      mshr_updates[m].allocated = mshr[m].allocated;
        //mshr[m].command <= '0;
      mshr_updates[m].addr = mshr[m].addr; 
      mshr_updates[m].trans_tag = mshr[m].trans_tag;
      mshr_updates[m].mem_data = mshr[m].mem_data; 
      mshr_updates[m].mem_size = mshr[m].mem_size;
      mshr_updates[m].ready = mshr[m].ready;
    end


    if (Dmem2Dcache_transaction_tag != 0) begin
      mshr_updates[Dmem2Dcache_transaction_tag].allocated = 1;
      mshr_updates[Dmem2Dcache_transaction_tag].addr = cachemiss_addr;
      mshr_updates[Dmem2Dcache_transaction_tag].mem_size = cachemiss_memsize;
      mshr_updates[Dmem2Dcache_transaction_tag].trans_tag = Dmem2Dcache_transaction_tag;
    end

    for (int m=0; m<NUM_MSHRS; m++) begin
      if (mshr_complete[m] == 1) begin
        mshr_updates[m].allocated = 0;
        //mshr[m].command <= '0;
        mshr_updates[m].addr = '0; 
        mshr_updates[m].trans_tag = '0;
        mshr_updates[m].mem_data = '0; 
        mshr_updates[m].ready = '0;
      end 
    end

    for (int m=0; m<NUM_MSHRS; m++) begin
      if (mshr[m].allocated && mshr[m].trans_tag == Dmem2Dcache_data_tag && Dmem2Dcache_data_tag != 0) begin
        // dcache[mshr[m].addr[SET_INDEX_BITS+2:3]][lru[mshr[m].addr[SET_INDEX_BITS+2:3]]].valid <= 1;
        // dcache[mshr[m].addr[SET_INDEX_BITS+2:3]][lru[mshr[m].addr[SET_INDEX_BITS+2:3]]].tag <= mshr[m].addr[31:32-TAG_WIDTH];
        mshr_updates[m].mem_data = Dmem2Dcache_data;
        //mshr[m].allocated <= 0;
        mshr_updates[m].ready = 1;
      end
    end

  end




  always_ff @(posedge clock) begin
    if (reset) begin
      for (int m=0; m<NUM_MSHRS; m++) begin
        mshr[m].allocated <= 0;
        // //mshr[m].command <= '0;
        // mshr[m].addr <= '0; 
        // mshr[m].trans_tag <= '0;
        // mshr[m].mem_data <= '0; 
        mshr[m].ready <= '0;
      end

      for (int s=0; s<NUM_SETS; s++) begin
        for (int w=0; w<ASSOCIATIVITY; w++) begin
          dcache[s][w].valid <= 0;
          dcache[s][w].tag <= '0;
          lru[s][w] <= w;
        end
      end
      lru_update_enable <= 0;
    end else begin


      for (int m=0; m<NUM_MSHRS; m++) begin // clear mshr entry when written to dcache
        // if (mshr_complete[m] == 1) begin
        mshr[m] <= mshr_updates[m];
          // mshr[m].allocated <= 0;
          //mshr[m].command <= '0;
          // mshr[m].addr <= '0; 
          // mshr[m].trans_tag <= '0;
          // mshr[m].mem_data <= '0; 
          // mshr[m].ready <= '0;
        // end 
      end

      // allocate MSHR on a cache miss
      if (proc2Dcache_command==MEM_LOAD && cache_hit != '1) begin
        cachemiss_addr <= proc2Dcache_raddr[cache_miss_rport]; // 📌 if mem load did not go to memory immediately, NEED TO STORE THE CACHE MISS ADDR!!!
        cachemiss_memsize <= proc2Dcache_size[cache_miss_rport];
        // 📌 IF Dmem2Dcache_transaction_tag comes back in the same cycle when instruction in sent to memory
        // mshr[Dmem2Dcache_transaction_tag].addr <= proc2Dcache_addr; 
        // mshr[Dmem2Dcache_transaction_tag].trans_tag <= Dmem2Dcache_transaction_tag;
        // 📌
      end

      // if (Dmem2Dcache_transaction_tag != 0) begin
      //   mshr[Dmem2Dcache_transaction_tag].allocated <= 1;
      //   //mshr[Dmem2Dcache_transaction_tag].command <= MEM_LOAD;

      //   // 📌 IF Dmem2Dcache_transaction_tag comes back in the same cycle when instruction in sent to memory
      //   mshr[Dmem2Dcache_transaction_tag].addr <= cachemiss_addr; 
      //   mshr[Dmem2Dcache_transaction_tag].trans_tag <= Dmem2Dcache_transaction_tag;
      // end
        // 📌



      if(read_operation || write_store || write_mshr) begin
        lru_update_enable <= 1;
      end else begin
        lru_update_enable <= 0;
      end

      if(read_operation) begin
        re_update_enable <= 1;
      end else begin
        re_update_enable <= 0;
      end

      if(write_mshr) begin
        wr_update_mshr <= 1;
      end else begin
        wr_update_mshr <= 0;
      end
      
      
      for (int i=0; i< NUM_SETS; i++) begin
        lru[i] <= lru_updates[i];
        lru_way[i] <= lru_updates[i][3];

      end
    

      // update dcache on mem response
      if (write_store) begin
        //if (proc2Dcache_command == MEM_STORE) begin
          dcache[current_write_set_index][lru_updates[current_write_set_index][3]].valid <= 1;
          dcache[current_write_set_index][lru_updates[current_write_set_index][3]].tag <= current_write_tag;
        //end
      end
      else if (write_mshr) begin
        for (int m=0; m<NUM_MSHRS; m++) begin
          if (mshr[m].ready) begin
            dcache[current_write_set_index][lru_updates[current_write_set_index][3]].valid <= 1;
            dcache[current_write_set_index][lru_updates[current_write_set_index][3]].tag <= current_write_tag;
          end
        end
      end
    end
  end





  // helper function LRU
  function automatic [ASSOCIATIVITY-1:0][WAY_INDEX_BITS-1:0] update_lru(input logic[ASSOCIATIVITY-1:0][WAY_INDEX_BITS-1:0] current_lru_order, input logic [WAY_INDEX_BITS-1:0] mru);
    logic [WAY_INDEX_BITS-1:0] pos;
    logic [ASSOCIATIVITY-1:0][WAY_INDEX_BITS-1:0] updated_lru_order;
    pos = 0;
    updated_lru_order[pos] = mru;
    pos = pos + 1;
    for (int i = 0; i < ASSOCIATIVITY; i = i + 1) begin
      if (current_lru_order[i] != mru) begin
          updated_lru_order[pos] = current_lru_order[i];
          pos = pos + 1;
      end
    end
    return updated_lru_order;
  endfunction


endmodule




// ✅📝📌❗️❓❌⭕️🛑