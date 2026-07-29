# fio I/O workload matrix

Command:

```bash
GPUC_SIZE=64M GPUC_RUNTIME=1 GPUC_REPEATS=5 \
GPUC_BS_LIST='4k 16k 128k' GPUC_CONCURRENCY_LIST='1 4' \
GPUC_QD_LIST='1 8 32' bash tests/io_workload_matrix.sh
```

Buffered read/write results use fio sync I/O. Baseline and Hook RAW cover 1/4
application threads; immutable compressed files use one thread in this matrix.
Baseline libaio random read separately covers true QD 1/8/32. `runs.csv` has
one row per operation and repeat; `summary.csv` reports mean and 95% CI.
