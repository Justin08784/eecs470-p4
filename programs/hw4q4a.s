# IPC testing
# loop limit; init to 10000
lui x1, 0x2
addi x1, x1, 0x710

li x2, 0
li x3, 0
li x4, 0
li x5, 0

lui x6, 0x1
sw x6, 0(x6)
lui x7, 0x2
addi x7, x7, 4
li x8, 0

li x9, 0
li x10, 0
li x11, 0
li x12, 0

loop:
    mul x2, x2, x2
    mul x3, x3, x3
    mul x4, x4, x4
    mul x5, x5, x5
    lw x31, 0(x6)
    lw x31, 4(x6)
    lw x31, 8(x6)
    lw x31, 12(x6)
    sw x7, 0(x7)
    sw x7, 4(x7)
    sw x7, 8(x7)
    sw x7, 12(x7)
    add x8, x8, x8

    addi x9, x9, 1
    addi x10, x10, 1
    addi x11, x11, 1
    addi x12, x12, 1

    addi x1, x1, -1
    bnez x1, loop
end:
	wfi


