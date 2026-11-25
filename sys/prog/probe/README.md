Probes of what a PE can reach. Each task has four blocks; block b works 1 KiB further into the data than block
b-1. Tensor-engine cores: one write to global L1 (kernel 7); 16 reads of global L1, the matrix Y (kernel 5); 16 reads
of L2, the reference Z (kernel 6). Then vector-unit cores: 16 reads of L2. The host waits after each task, so the
trace shows which blocks do not finish. Run with CHECK=0 and a short TIMEOUT.
