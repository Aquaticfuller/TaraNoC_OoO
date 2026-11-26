The matrix product of `../gemm_mix` (32 blocks of 4 rows, both PE types) with the speed hint 2: a block takes about
four times as long on a vector unit. Checks that the blocks of a small task then all go to tensor engines, at home
or in a domain nearby. Made with `scripts/gemm_prog.py gemm_hint --cls 3 --vslow 2`.
