# Intel PCM 主机 DRAM bandwidth 正式结果

## 方法

- CPU：Intel Xeon 6505P（Granite Rapids）；
- GPU：Tesla V100-SXM2-32GB；
- PCM：Intel 官方仓库
  `4246ea47f27c471bcc8484c065886f31f449933e`；
- 场景：无解压 Baseline、CPU LZ4、GPU LZ4；
- 处理量：CPU/GPU 均限制在约 4096 MiB/s；
- 业务：4 个整数计算 worker，解压提交和 GPU worker 固定到 core 0；
- 采集：`pcm-memory` external-program 模式覆盖完整 10 秒场景；
- 重复：每场景五轮，并按轮次旋转执行顺序；
- 口径：全系统 IMC bandwidth，不是单进程内存流量。

## 结果

| 场景 | DRAM Read MB/s | 95% CI | DRAM Write MB/s | 95% CI | DRAM Total MB/s | 95% CI |
|---|---:|---:|---:|---:|---:|---:|
| Baseline | 55.93 | ±1.68 | 41.08 | ±0.55 | 97.01 | ±2.23 |
| CPU LZ4 | 72.02 | ±18.43 | 44.08 | ±1.10 | 116.09 | ±19.26 |
| GPU LZ4 | 104.96 | ±20.95 | 2970.64 | ±334.96 | 3075.61 | ±342.02 |

CPU/GPU 实际解压吞吐分别为 4091.41±2.20 和 4090.33±0.67 MiB/s。GPU 总 DRAM
带宽约为 CPU 的 26.49 倍，写带宽约为 CPU 的 67.39 倍；GPU 相对 Baseline
增加约 2978.59 MB/s 的主机 DRAM 流量。

## 解释与边界

该结果否定“当前 GPU 路径同时降低主机 DRAM bandwidth”的主张。CPU LZ4 的输入
和输出反复驻留在 CPU cache，IMC 只观察到较小的外部 DRAM 流量；GPU 解压结果
经 D2H DMA 写回 pinned host buffer，写入会到达内存控制器，因此 GPU 场景出现
约 3 GB/s 的 DRAM 写带宽。数值低于 4096 MiB/s 逻辑处理量，可能包含平台 DMA、
缓存一致性和 PCM 计数口径差异，不能直接把二者相除解释为复制效率。

本实验与先前 CPU-offload 结论并不矛盾：GPU 路径减少的是主机 CPU 计算开销和
业务争用，不是主机 DRAM 带宽。它同时保留了约 2.1 MiB 更高 RSS，因此当前实现
在 DRAM 容量和带宽两个口径上均没有节省证据。

`runs.csv` 保存逐轮指标，`summary.csv` 保存均值和 95% CI，`raw/` 保存每轮 PCM
原始 CSV、应用输出与空诊断文件。
