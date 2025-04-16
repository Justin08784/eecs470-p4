addi x5, x0, 0x1b

addi x1, x0, 1  # LSB mask to check if n is even
addi x2, x0, 3  # used to multiply n by 3 if n is odd
addi x4, x0, 0  # number of reductions needed to reach 1
loop:
    beq x5, x1, end
    add x4, x4, 1
    and x3, x5, x1
    beqz x3, is_even
    mul x5, x5, x2
    add x5, x5, 1
    j loop
is_even:
    srli x5, x5, 1
    j loop
end:
    wfi
