    .text
    .globl _start
_start:
    jal ra, fun
    nop
    wfi
fun:
    li x3, 1
    jalr x0, ra, 0
    wfi