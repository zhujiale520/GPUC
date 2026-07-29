# System resource profile

Five repeats each of no decompression, CPU LZ4 and GPU LZ4 at a target
4096 MiB/s. Every run retains raw `pidstat -u -r -w`, `sar -u -r -B -W`,
200 ms nvidia-smi samples and the workload output. `capability_probe.txt`
records why perf/PCM/RAPL hardware metrics are unavailable on this host.
