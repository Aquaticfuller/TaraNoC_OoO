One line of `prog.txt` is one task instruction:

    op hd_v hd hs1_v hs1 follow kill hs2_v hs2 cls nblk kern arg len addr

`op`: 0 TLoad, 1 TRun, 2 TJoin, 3 TFree. `cls`: bit 0 tensor engines, bit 1 vector units. `kern` is the kernel
the PE program runs (`tsched_agent` in the cluster hardware): 1 matrix product on the tensor engine, 3 check of the
result, others a placeholder.

A `TJoin` with bit 0 of `arg` set makes the host model of the simulation wait until the scheduler is idle before it
feeds the next instruction. A field may be `@name`, the address of symbol `name` in the linked PE program; `scripts/link_prog.py` resolves it
before a run.

This program: 16 placeholder blocks on the tensor engines and a join the host waits for, so that every core
has left its boot code; then: load a tile of 16,384 bytes (the matrix X, 128 x 64 half-precision values) from L2 into an L1 slot;
a task of 8 matrix blocks on the tensor engines that follows the load (block b needs rows 16b .. 16b+15 of X, which
is chunk b of the load); a task of 12 placeholder blocks on the vector units; a join; one block that checks the
result; a join.
