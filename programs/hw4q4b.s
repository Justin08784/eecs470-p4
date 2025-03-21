# Dependency testing
# loop limit; init to 10000
lui x1, 0x2
addi x1, x1, 0x710
li x2, 1
li x3, 0

loop:
    addi x3, x3, 1
    addi x1, x1, -1
    mul  x1, x1, x2
    bnez x1, loop
wfi