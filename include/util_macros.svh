`ifndef UTIL_MACROS_SVH
`define UTIL_MACROS_SVH

// helpful macros
`define MIN(a, b) ((a) < (b) ? (a) : (b))
`define MAX(a, b) ((a) > (b) ? (a) : (b))

`define CNT_TYPE(max) logic [$clog2(max+1)-1:0] // smallest bit-vector to store max
`define CNT_SIZE(max) ($clog2(max+1))           // ...and number of bits in that type

`define IDX_TYPE(len) logic [$clog2(len)-1:0]   // smallest bit-vector to index an array of length len
`define IDX_SIZE(len) ($clog2(len))             // ...and number of bits in that type

`define UCAST_LEN(n, max) ($clog2(max+1)'(unsigned'(n)))
`define UCAST_FIT(n) (($clog2(n+1))'(unsigned'(n)))    // cast fit unsigned


`endif // UTIL_MACROS_SVH