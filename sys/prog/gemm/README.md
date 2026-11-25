One line of `prog.txt` is one task instruction:

    op hd_v hd hs1_v hs1 follow kill hs2_v hs2 cls nblk kern arg len addr

`op`: 0 TLoad, 1 TRun, 2 TJoin, 3 TFree. `cls`: bit 0 tensor engines, bit 1 vector units. `kern` is the kernel
the PE program runs (`tsched_agent` in the cluster hardware): 1 matrix product on the tensor engine, 3 check of the
result, others a placeholder.

This program: load a tile; a task of 4 matrix blocks on the tensor engines that follows the load; a task of 12
placeholder blocks on the vector units; a join; one block that checks the result; a join.
