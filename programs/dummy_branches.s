# test_branch_flood.s
    li x1, 0
    li x2, 1

    # Branches that will NOT be taken
    beq x1, x2, not_taken1
    beq x1, x2, not_taken2
    beq x1, x2, not_taken3
    beq x1, x2, not_taken4
    beq x1, x2, not_taken5
    beq x1, x2, not_taken6
    beq x1, x2, not_taken7
    beq x1, x2, not_taken8
    beq x1, x2, not_taken9
    beq x1, x2, not_taken10
    beq x1, x2, not_taken11
    beq x1, x2, not_taken12
    beq x1, x2, not_taken13
    beq x1, x2, not_taken14
    beq x1, x2, not_taken15
    beq x1, x2, not_taken16
    beq x1, x2, not_taken17
    beq x1, x2, not_taken18
    beq x1, x2, not_taken19
    beq x1, x2, not_taken20

done:
    li x3, 42     # To visually confirm we reached here
    wfi

# Dummy labels to avoid assembler errors
not_taken1: nop
not_taken2: nop
not_taken3: nop
not_taken4: nop
not_taken5: nop
not_taken6: nop
not_taken7: nop
not_taken8: nop
not_taken9: nop
not_taken10: nop
not_taken11: nop
not_taken12: nop
not_taken13: nop
not_taken14: nop
not_taken15: nop
not_taken16: nop
not_taken17: nop
not_taken18: nop
not_taken19: nop
not_taken20: nop