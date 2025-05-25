    li x2, 1000
    li x4, 1 # even mask
    li x5, 3 # quad mask
    li x8, 1 # triple if 0
loop:
    and x6, x2, x4
    beqz x6, even
    nop
    nop
back_even:
#     and x7, x2, x5
#     beqz x7, quad
#     nop
#     nop
# back_quad:
    beqz x8, trip
    nop
    nop
back_trip:
    addi x8, x8, -1
    addi x2, x2, -1     # 10: decrement counter
    bnez x2, loop       # 14: if x2 != 0, jump back to loop
    wfi                 # 18: wait for interrupt
even:
    li x3, 2
    nop
    nop
    j back_even
trip:
    li x3, 3
    li x8, 3
    nop
    nop
    j back_trip
# quad:
#     li x3, 4
#     nop
#     nop
#     j back_quad