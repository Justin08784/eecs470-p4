# bunch of non taken function calls. Tests RAS checkpointing (should reset to empty each time).
    .text
    .globl _start
_start:
    beq x0, x0, l1
    jal ra, dummy1
    jal ra, dummy2
    jal ra, dummy2
l1:
    beq x0, x0, l2
    jal ra, dummy3
l2:
    beq x0, x0, l3
    jal ra, dummy4
    jal ra, dummy3
    jal ra, dummy2
    jal ra, dummy1
l3:
    nop
    wfi
dummy1:
    jalr x0, ra, 0
dummy2:
    jalr x0, ra, 0
dummy3:
    jalr x0, ra, 0
dummy4:
    jalr x0, ra, 0