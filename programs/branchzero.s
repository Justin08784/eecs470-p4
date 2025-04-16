_start:
    beq x0, x0, skip   # Always branch
    add x1, x0, x0     # Skipped
    add x2, x0, x0     # Skipped

skip:
    wfi                # Wait for interrupt
