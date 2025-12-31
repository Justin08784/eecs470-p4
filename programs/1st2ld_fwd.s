data = 0x1000
li  x1, data
li  x2, 1
# li  x3, 32
sw x0, 0(x1)
sh x2, 0(x1)
addi x2, x2, 1
sb x2, 2(x1)
addi x2, x2, 1
sb x2, 3(x1)
lw x3, 0(x1)
wfi