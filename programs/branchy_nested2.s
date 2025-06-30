    li x1, 50   # 0
loop1:
    li x2, 3    # 1
loop2:
    li x3, 2    # 2
loop3:
    add x3, x3, -1
    nop
    nop
    nop
    bnez x3, loop3  # 7
    add x2, x2, -1
    nop
    nop
    nop
    bnez x2, loop2  # 12
    add x1, x1, -1
    nop
    nop
    nop
    bnez x1, loop1  # 17
wfi