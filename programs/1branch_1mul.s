    li x1, 2            # 0  (0)
loop:
    mul x4, x1, x1      # 4  (1)
    addi x1, x1, -1     # 8  (2)
    bnez x1, loop       # c  (3)
    wfi                 # 10 (4)
