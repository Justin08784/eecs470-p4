# Tests RAS
# Not actually an ideal test, since this jal and jalr usage is unconventional
# (and our predecoder wont identify these as ret's call's). Probably need memory
# to test deeper callstacks + recursion.

# If we change the ret condition to...
# ret  = (rd == `ZERO_REG);
# ...it will successfully predict all branches (but this is probably too wide a net).
    .text
    .globl _start
_start:
    li x2, 100      # 0

loop:
    jal ra, f1      # 1
    nop             # 2
    nop
    nop
    nop
    bnez x2, loop   # 6
    wfi

f1:
    jal t0, f2      # 8
    nop
    nop
    nop
    nop
    jalr x0, ra, 0  # 13 (d)

f2:
    jal t1, f3      # 14 (e)
    nop
    nop
    nop
    nop
    jalr x0, t0, 0  # 19 (13)

f3:
    nop
    nop
    nop
    nop
    addi x2, x2, -1
    jalr x0, t1, 0  # 25 (19)