# Experiment result layout

Automated benchmarks write local runs to `results/local/<experiment>_<UTC timestamp>/`.
That directory is ignored by Git so repeated local runs do not pollute the worktree.

For a result used in the final report, copy the complete run directory to:

```text
results/final/<experiment>/<run_id>/
```

Each committed final run must include:

- `environment.txt`: Git commit, kernel, GPU/driver, CUDA/fio version and parameters;
- raw fio JSON or equivalent tool output;
- `runs.csv`: one row per repetition;
- `summary.csv`: sample count, mean, standard deviation and 95% confidence interval;
- checksums and GPUC state for every input file;
- a short `README.md` explaining the exact command and whether the run is warm-cache,
  cold-cache or `O_DIRECT`.

Do not commit a chart without the raw data used to generate it.
