    .text
    .globl _start
    wfi
_start:
    li x2, 5              # loop counter (number of outer calls)
main_loop:
    li x3, 4              # recursion depth counter for functions
    jal ra, fun1          # start function call loop
    addi x2, x2, -1       # decrement main loop counter
    bnez x2, main_loop    # repeat if x2 != 0
    wfi                   # end program

# fun1 randomly branches to fun2 or fun3 based on x3
fun1:
    addi x3, x3, -1       # decrement depth
    bltz x3, end_fun      # if x3 < 0, return
    andi x4, x3, 1        # check LSB of x3
    beq x4, x0, call_fun2
    jal ra, fun3          # if LSB is 1, call fun3
    jalr x0, ra, 0        # return
call_fun2:
    jal ra, fun2
    jalr x0, ra, 0

# fun2 always calls fun1 again if depth allows
fun2:
    addi x3, x3, -1
    bltz x3, end_fun
    jal ra, fun1
    jalr x0, ra, 0

# fun3 just ends the recursion
fun3:
    nop
    nop
    jalr x0, ra, 0

# Common return
end_fun:
    jalr x0, ra, 0
