A larger matrix task: 128 blocks of 4 rows (X is 512 x 64, a load of 64 KiB into one slot), tensor engines only.
Reference for `../big_mix` and `../big_hint`. On one domain (16 tensor engines) it takes eight rounds, on four
domains with idle neighbours two. Made with `scripts/gemm_prog.py big_t --blocks 128`.
