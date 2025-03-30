#!/bin/bash

# Ensure at least two arguments are provided
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 <test_name> <out_ext> [num_lines]"
    exit 1
fi

# Assign command-line arguments to variables
test_name=$1
out_ext=$2
num_lines=$3  # Optional third argument

# Construct the diff command
if [ -n "$num_lines" ]; then
    cmd="diff <(head -n $num_lines correct_out/${test_name}.${out_ext}) <(head -n $num_lines output/${test_name}.${out_ext})"
else
    cmd="diff correct_out/${test_name}.${out_ext} output/${test_name}.${out_ext}"
fi

# Print and execute the command
echo "$cmd"
eval "$cmd"
