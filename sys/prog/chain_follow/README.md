The chain of `../chain_c1` with the chain flag on stages 2 and 3: the scheduler releases the k-th block of a stage when
k blocks of the stage before are done, and the kernels pass on which blocks those were through lists in L1. Three task
instructions. Made with `scripts/chain_prog.py chain_follow --follow 1`.
