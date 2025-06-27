    li x1, 100
loop1:
    li x2, 2
loop2:
    li x3, 3
loop3:
    add x3, x3, -1
    nop
    nop
    nop
    bnez x3, loop3
    add x2, x2, -1
    nop
    nop
    nop
    bnez x2, loop2
    add x1, x1, -1
    nop
    nop
    nop
    bnez x1, loop1
wfi

#     li x1, 0          # outer loop i = 0
# outer_loop:
#     li x2, 0          # middle loop j = 0
# middle_loop:
#     li x3, 0          # inner loop k = 0
# inner_loop:
#     addi x3, x3, 1    # k++
#     li  x4, 5   # inner_loop
#     blt x3, x4, inner_loop # while  k < 5
# 
#     addi x2, x2, 1    # j++
#     li  x4, 4
#     blt x2, x4, middle_loop # while  k < 5
# 
#     addi x1, x1, 1    # i++
#     li x4, 3
#     blt x1, x4, outer_loop # while k < 5
# wfi


# loop:
#     addi x3, x2, 3      # 4: x3 = x2 + 3 (just some operation)
#     mul x4, x2, x3      # 8 x4 = x2 * x3
#     addi x2, x2, -1     # 10: decrement counter
#     bnez x2, loop       # 14: if x2 != 0, jump back to loop
#     wfi                 # 18: wait for interrupt
