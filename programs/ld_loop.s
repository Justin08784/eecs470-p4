    li x1, 0            # 0
    li x2, 16           # 4
loop:
    lw x3, 0(x1)        # 8
    addi x1, x1, 4      # 12
    addi x2, x2, -1     # 16
    bnez x2, loop       # 20
    wfi                 # 24
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
