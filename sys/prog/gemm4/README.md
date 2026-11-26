The program of `../gemm` for four domains of real tiles (cluster configuration `cluster_4x4`, scheduler with
`TSCHED_DOM_PER_SIDE=2`): the task on the loaded tile has 32 blocks, twice the tensor engines of the domain that
holds the tile, so the balancer moves blocks to the other domains. The PEs there read the tile in its home domain.

Made with `scripts/gemm_prog.py gemm4 --spare 48`. The matrix task names its rows per block in its argument, the check
the number of elements; the PE program's matrix has 512 rows and a task may cover a part of them.
