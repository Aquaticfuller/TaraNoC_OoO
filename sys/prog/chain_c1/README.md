A chain of three kernels over one matrix of 512 rows, as three whole tasks of 128 blocks: a projection on the tensor
engines, the softmax of every row on the vector units, a second projection on the result. Each task waits for the
whole task before it. Then the result is checked against the reference. Made with `scripts/chain_prog.py chain_c1`.
