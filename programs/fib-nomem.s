    .text
    .globl _start

_start:
    li x5, 0          # f0 = 0
    li x6, 1          # f1 = 1
    li x7, 1600       # n = 1600?
    li x8, 2          # i = 2

fib_loop:
    beq x8, x7, end   # end if i == n
    add x9, x5, x6    # f2 = f0 + f1
    mv  x5, x6        # f0 = f1
    mv  x6, x9        # f1 = f2

    addi x8, x8, 1    # ++i
    jal x0, fib_loop

end:
    mv x10, x6        # store result in x10
    wfi