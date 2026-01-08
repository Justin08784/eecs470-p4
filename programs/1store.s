data = 0x1000
li  x1, data
li  x2, 2
li  x3, 32
# sw  x2, 0(x1)
loop:
sw x2, 0(x1)        # 8
sw x2, 4(x1)        # 8
addi x2, x2, 1      # 12
addi x3, x3, -1     # 16
bnez x3, loop       # 20
wfi

# li  x3, 10
# loop:
# addi x3, x3, -1     # 16
# bnez x3, loop       # 20

# li  x3, 100
# wfi
# loop:
# sw x2, 0(x1)        # 8
# addi x2, x2, 1      # 12
# addi x3, x3, -1     # 16
# bnez x3, loop       # 20
