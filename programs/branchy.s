    addi x2, x0, 100      # 0: x2 = 5 (loop counter)
loop:
    addi x3, x2, 3      # 4: x3 = x2 + 3 (just some operation)
    mul x4, x2, x3      # x4 = x2 * x3
    add x5, x2, x3      # 8: x5 = x2 + x3
    addi x2, x2, -1     # c: decrement counter
    bnez x2, loop       # 10: if x2 != 0, jump back to loop
    wfi                 # 14: wait for interrupt
