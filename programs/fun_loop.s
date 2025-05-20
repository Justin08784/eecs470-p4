    .text
    .globl _start
_start:
    addi x2, x0, 10     # 0: x2 = 100 (loop counter)
loop:
    jal ra, fun
    nop
    nop
    nop
    nop
    jal ra, fun
    nop
    nop
    addi x2, x2, -1     # decrement loop counter
    bnez x2, loop
    wfi
fun:
    nop
    nop
    nop
    jalr x0, ra, 0