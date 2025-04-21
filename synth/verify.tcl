clear -all
# Add files to include here
analyze -sv09 verilog/ROB.sv verilog/FIFO_sva.svh verilog/FIFO_fv.sv verilog/memDP.sv

# Elaborate design with parameters specified
# Use -disable_auto_bbox so operations (ex: modulo) aren't black boxed
# -sv09_expression_mode allows use of s_eventually
elaborate -top FIFO_fv -disable_auto_bbox -sv09_expression_mode -parameter WIDTH 44 -parameter DEPTH 32

# Set clock and reset
clock clock
reset reset

# Disable big assert on function correctness
assert -disable <embedded>::FIFO_fv.dut.DUT_sva.DataOutErr

# Adding -bg lets you open violation traces while running proof
prove -all -bg
