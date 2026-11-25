The matrix product of `../gemm4` with all 32 blocks on vector units (cls 2): checks the half-precision GEMM kernel on
the Spatz units against the reference. Warm-up, load of the tile X, 32 blocks of 4 rows following the load, join,
16 check blocks on tensor-engine cores, join, report, join. Runs on one or on four domains.
