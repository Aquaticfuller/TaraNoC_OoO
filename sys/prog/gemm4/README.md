The program of `../gemm` for four domains of real tiles (cluster configuration `cluster_4x4`, scheduler with
`TSCHED_DOM_PER_SIDE=2`): the task on the loaded tile has 32 blocks, twice the tensor engines of the domain that
holds the tile, so the balancer moves blocks to the other domains. The PEs there read the tile in its home domain.
