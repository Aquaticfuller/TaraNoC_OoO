Separates the two things the check loop does that the single probes do not. Each block reads 512 values, block b at
element 512 b. (1) 16 blocks at once reading only global L1; (2) 16 blocks at once reading only L2; (3) 4 blocks
reading L1 and L2 in turn; (4) 16 blocks reading L1 and L2 in turn. The host waits after each task; the first task
that does not finish is the case that hangs. Run with CHECK=0 and a short TIMEOUT.
