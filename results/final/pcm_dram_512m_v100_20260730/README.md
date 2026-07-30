# V100 512 MiB 稳态 Intel PCM DRAM bandwidth

- 工作集：512 MiB 轮转数据，每批 128 × 128 KiB。
- 吞吐：CPU LZ4 与 GPU nvCOMP LZ4 都限制在约 4096 MiB/s。
- 场景：Baseline、CPU、GPU 轮换顺序，各五轮，每轮稳态 10 秒。
- 采样：PCM 每秒采样；程序初始化、压缩、warmup 完成后通过 ready/start 握手
  开始，只汇总完全位于 start/end 内的 9 个稳态区间。
- 口径：全系统内存控制器带宽，不是单进程精确流量。

核心结果：

| 场景 | Read MB/s | Write MB/s | Total MB/s |
|---|---:|---:|---:|
| Baseline | 23.80 ±4.66 | 20.53 ±1.53 | 44.33 ±6.20 |
| CPU LZ4 | 4416.34 ±22.62 | 4329.12 ±9.45 | 8745.46 ±29.06 |
| GPU LZ4 | 86.40 ±3.51 | 4483.11 ±9.70 | 4569.51 ±7.15 |

相同逻辑吞吐下，GPU 相对 CPU 总 DRAM bandwidth 低约 47.75%，主要因为 CPU
路径同时产生约 4.42 GB/s 读取与 4.33 GB/s 写入，而 GPU 输入为压缩数据、主机
读取仅约 86 MB/s。GPU 的 D2H 写入约 4.48 GB/s，比 CPU 写入高约 3.56%，因此
不能宣称 GPU 消除了主机写回或降低了 DRAM 容量。

`runs.csv` 保存逐轮均值，`summary.csv` 保存 mean 与 95% CI；`raw/` 包含全部
PCM CSV、程序输出、阶段时间戳和空 stderr。
