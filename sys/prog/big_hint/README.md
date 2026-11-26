The task of `../big_t` for both PE types, with the speed hint 2 (a vector block takes about four times as long):
vector units take blocks only while the tensor engines of the domain have a long backlog and no tensor engine
within reach is without work. Made with `scripts/gemm_prog.py big_hint --blocks 128 --cls 3 --vslow 2`.
