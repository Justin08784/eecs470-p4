    addi x2, x0, 500      # 0: x2 = 100 (loop counter)
loop:
    addi x3, x2, 3      # 4: x3 = x2 + 3 (just some operation)
    mul x4, x2, x3      # 8 x4 = x2 * x3
    addi x2, x2, -1     # 10: decrement counter
    bnez x2, loop       # 14: if x2 != 0, jump back to loop
    wfi                 # 18: wait for interrupt
