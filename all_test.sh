make test1.out \
    test2.out \
    test3.out \
    mult_no_lsq.out \
    btest1.out \
    btest2.out \
    evens.out \
    sampler.out \
    copy.out \
    mult_orig.out

./ck.sh test1 wb
./ck.sh test2 wb
./ck.sh test3 wb
./ck.sh mult_no_lsq wb
./ck.sh btest1 wb
./ck.sh btest2 wb
./ck.sh evens wb
./ck.sh sampler wb
./ck.sh copy wb
./ck.sh mult_orig wb