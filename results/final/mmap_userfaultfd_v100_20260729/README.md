# userfaultfd mmap 单线程正式结果

Tesla V100、64/256 MiB、每组五轮，`GPUC_MMAP_MODE=userfaultfd`。测试在
`mmap()` 返回后先访问一个随机页，再用单线程扫描逐页唯一非零 pattern。

256 MiB GPU COMPRESSED：

- `mmap()`：0.215 ± 0.011 ms；
- 首次 fault：146.502 ± 3.836 ms；
- 完整扫描：5651.449 ± 367.254 ms；
- 五轮 mismatch 均为 0。

旧同步方案的 256 MiB 返回约 1.21 s，因此 userfaultfd 解决了返回延迟；当前
0.215 ms 已包含返回前的 handler 资源/header 初始化。首次 CUDA 初始化与后续
完整解压仍需分别报告。原始逐轮数据见 `results.csv`，均值与 95% CI 见
`summary.csv`。
