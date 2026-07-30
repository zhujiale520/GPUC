# V100 稳态进程级 perf 通用事件

- 命令：`GPUC_RUNTIME=10 GPUC_REPEATS=5 GPUC_WORKSET_MIB=512 GPUC_TARGET_MIB_S=4096 bash tests/perf_offload.sh`
- 场景：Baseline、CPU LZ4、GPU nvCOMP LZ4，轮换顺序，各五轮。
- 计时：allocation、CPU compression 和 warmup 之后启用，覆盖 10 秒稳态。
- 范围：当前进程及继承线程的用户态事件，不包含 kernel/hypervisor。
- 限制：`cache-references/cache-misses` 是 Linux 通用硬件事件，不是本机不支持的
  精确 `LLC-loads/LLC-load-misses`。

`runs.csv` 是逐轮数据，`summary.csv` 给出 mean 和 95% CI，`raw/` 保存每轮应用
输出和计数器原始 CSV。
