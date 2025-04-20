TESTS=(
    test1
    test2
    test3
    test8
    mult_no_lsq
    btest1
    btest2
    evens
    sampler
    copy
    mult_orig
    insertion
    fib_long
    saxpy
    fib_rec
)

EXTS=(
    wb
    out
)

# Build all tests
make ${TESTS[@]/%/.out}

# Diff
for t in "${TESTS[@]}"; do
    for ext in "${EXTS[@]}"; do
        echo "Diffing $t.$ext..."
        diff "correct_out/${t}.${ext}" "output/${t}.${ext}"
    done
done
