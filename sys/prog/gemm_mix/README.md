The matrix product of `../gemm4` as one task whose 32 blocks may run on either PE type (cls 3): each block runs on
the tensor engine or on the vector unit of the core it lands on, with the same rows. The result is checked as in
`../gemm4`.
