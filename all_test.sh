TESTS=(
    # no mem ops
    branchy_nested
    branchy
    branchzero
    btest1
    btest2
    dummy_branches
    halt
    hw4q4b
    hw4
    mult_no_lsq
    test1
    test2
    test3

    # contains mem ops
    2store_1evi
    copy_long
    copy
    crt
    evens_long
    evens
    fib_long
    fib_rec
    fib
    haha
    hw4q4a
    hw4q4c
    insertion
    mult_orig
    no_hazard
    parallel
    sampler
    saxpy
    test4
    test5
    test6
    test7
    test8
    alexnet
    backtrack
    basic_malloc
    bfs
    dft
    fc_forward
    graph
    insertionsort
    matrix_mult_rec
    mergesort
    omegalul
    outer_product
    priority_queue
    quicksort
    sort_search
)

EXTS=(
    wb
    out
)

# Build all tests
make ${TESTS[@]/%/.out}

# correct_out_path="$HOME/eecs470/p3-w25.eshinj/output"
correct_out_path="$HOME/p4/correct_out"

# Diff
mkdir diffs
rm -rf diffs/*

for t in "${TESTS[@]}"; do
    for ext in "${EXTS[@]}"; do
        echo "Diffing $t.$ext..."
        diff "${correct_out_path}/${t}.${ext}" "output/${t}.${ext}" > "diffs/${t}.${ext}.diff"
        # diff "correct_out/${t}.${ext}" "output/${t}.${ext}"
    done
done

for file in diffs/*.diff; do
    if [ -s "$file" ]; then
        echo Nonzero diff in "$file"
    fi
done
