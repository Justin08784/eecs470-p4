TESTS=(
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
    evens_long
    fib
    haha
    halt
    bfs
    fc_forward
    graph
    basic_malloc
    backtrack
    sort_search
    outer_product
    priority_queue
    insertionsort
    matrix_mult_rec
    mergesort
    omegalul
    quicksort
    sort_search
    dft
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
        diff "correct_out/${t}.${ext}" "output/${t}.${ext}" > "diffs/${t}.${ext}.diff"
        # diff "correct_out/${t}.${ext}" "output/${t}.${ext}"
    done
done

for file in diffs/*.diff; do
    if [ -s "$file" ]; then
        echo Nonzero diff in "$file"
    fi
done