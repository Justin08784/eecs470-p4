// btb_sva.svh

// Packed mirror for assertions
logic [`BTB_ENTRIES-1:0] valid_bits;

always_comb begin
  for (int i = 0; i < `BTB_ENTRIES; i++) begin
    valid_bits[i] = valid_array[i];
  end
end

// use valid_bits instead of invalid memory op
property no_write_on_reset;
  @(posedge clock)
    reset |=> !(|valid_bits);
endproperty
assert property (no_write_on_reset);

// Write only when is_taken is high
generate
  for (genvar i = 0; i < `N; i++) begin
    property write_on_taken;
      @(posedge clock)
        !reset && fetch_in.is_taken[i] |=> valid_array[fetch_in.correct_PC[i][9:2]];
    endproperty
    assert property (write_on_taken);
  end
endgenerate

// Index must be in range
generate
  for (genvar i = 0; i < `N; i++) begin
    property index_in_range;
      @(posedge clock)
        fetch_in.is_taken[i] |-> (fetch_in.correct_PC[i][9:2] < `BTB_ENTRIES);
    endproperty
    assert property (index_in_range);
  end
endgenerate
