data = 0x1000
data2 = 0x2000
li  x1, data
li  x3, data2
li  x2, 2
sw  x2, 0(x1)
li  x2, 4
sw  x2, 0(x3)
wfi
