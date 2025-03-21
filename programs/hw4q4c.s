# LSQ
li x1, 5
lui x2, 0x1
li x11, 55
lui x22, 0x2

lui x3, 0x2
addi x3, x3, 0x710

loop: 
    addi x1, x1, 1
    addi x2, x2, 1
    addi x11, x11, 5
    addi x22, x22, 9

    sw x1, 0(x2)
    lw x4, 0(x2)
    sw x11, 0(x22)
    lw x10, 0(x22)

    addi x3, x3, -1
    bnez x3, loop
wfi

