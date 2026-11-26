The matrix product of `../gemm4` as one task whose 32 blocks may run on either PE type (cls 3): each block runs on
the tensor engine or on the vector unit of the core it lands on, with the same rows. The result is checked as in
`../gemm4`.

Made with `scripts/gemm_prog.py gemm_mix --cls 3`. The matrix task names its rows per block in its argument, the check
the number of elements; the PE program's matrix has 512 rows and a task may cover a part of them.
