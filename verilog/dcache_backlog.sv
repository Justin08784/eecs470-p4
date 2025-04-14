/* Request to MEM */
MISS_PKT miss, miss_n;

/* FILL handling. Handle MEM tag */
always_comb begin
    mshr_n = mshr;
    miss_n = '0;
    mem_out_command = MEM_NONE;

    if (ld_vld && !ld_hit) begin
        mem_out_command = MEM_LOAD;
        mem_out_addr = ld_addr;
        miss_n = '{
            addr : ld_addr,
            size : ld_size
        };
    end else if (st_vld && !st_hit) begin
        mem_out_command = MEM_LOAD;
        mem_out_addr = st_addr;
        miss_n = '{
            addr : st_addr,
            size : st_size
        };
    end

    if (mem_in_transaction_tag != 0) begin
        mshr_n[mem_in_transaction_tag] = '{
            vld         : 1,
            addr        : miss.addr,
            mem_data    : '0,
            mem_size    : miss.size,
            ready       : 0
        };
    end
end


// Header update after fill
for (int w = 0; w < ASSOC; ++w) begin
    if (!victim_msk[fl_sid][w])
        continue;
    /* TODO: need to write back if dirty. This just overwrites i.e.
    assumes clean */
    cache_hdr_n.vld[fl_sid][w]     = 1;
    cache_hdr_n.dirty[fl_sid][w]   = 0;
    cache_hdr_n.tag[fl_sid][w]     = fl_tag;
    cache_hdr_n.age[fl_sid]        = '0;
end

