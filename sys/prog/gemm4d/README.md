As `../gemm4`, but the matrix task computes on a tile that the scheduler places in a domain other than domain 0, so
that the numbering of domains between the scheduler (row by row) and the cluster (Z-order) is exercised. Three
loads of the same tile are issued after the warm-up: with every domain idle, placement puts them into scheduler
domains 0, 3 and 2 (equal work goes to the domain after the one served last, stride 3). Scheduler domain 2 is
cluster rectangle 1. The matrix task (32 blocks) follows the third load; the first two are freed.

Made with `scripts/gemm_prog.py gemm4d --place 2 --spare 48`. The matrix task names its rows per block in its argument, the check
the number of elements; the PE program's matrix has 512 rows and a task may cover a part of them.
