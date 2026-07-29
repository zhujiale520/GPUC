# V100 高并发复测（2026-07-25，已作废）

> **作废原因：**GPUC 紧凑格式的 56 B header、压缩块 offset 和长度不满足
> O_DIRECT 对齐要求。复核发现当时 Hook 在 `direct=1` 打开时 header 探测失败，
> fio 实际可能读取物理压缩/稀疏文件而没有透明解压。以下数据仅保留用于问题追溯，
> 不得进入报告、PPT 或视频。修复后的 Hook 会显式清除 managed fd 的 `O_DIRECT`，
> 实验脚本也禁止把该路径称为 O_DIRECT。

## 条件

- GPU：Tesla V100-SXM2-32GB，compute capability 7.0
- Driver/CUDA capability：570.181 / 12.8
- Kernel：Linux 5.15.0 x86_64
- fio：3.16，sync engine，`direct=1`
- 输入：512 MiB、逐页确定性非零 pattern
- 块大小：128 KiB
- 每组：15 秒，重复 5 次，轮换执行顺序
- 命令：

```bash
GPUC_SIZE=512M GPUC_RUNTIME=15 GPUC_REPEATS=5 \
GPUC_BS_LIST=128k GPUC_JOBS_LIST='1 32' \
bash tests/benchmark_high_concurrency.sh
```

## 结果

| 方案 | jobs | mean MiB/s | std | 95% CI |
|---|---:|---:|---:|---:|
| Baseline dense | 1 | 255.955 | 18.626 | ±16.326 |
| Hook RAW | 1 | 251.839 | 7.642 | ±6.699 |
| GPU Compressed | 1 | 583.664 | 79.415 | ±69.611 |
| Baseline dense | 32 | 383.237 | 6.297 | ±5.520 |
| Hook RAW | 32 | 383.982 | 2.573 | ±2.255 |
| GPU Compressed | 32 | 4779.172 | 35.735 | ±31.323 |

三份文件的逻辑 SHA-256 均为
`174e460e6c9c67e3c7bce298f6a2e7ff50f88493071780360eafb0e78455f653`。
GPU Compressed 物理占用约 16.9 MB，而 dense Baseline 约 536.9 MB。

GPU Compressed 数值是应用看到的“有效逻辑带宽”。对高度可压缩数据，底层物理
读取量显著降低，因此该值可以高于 dense Baseline；它不能单独解释为 GPU kernel
解压吞吐，也不能推广到低压缩率数据。下一步必须补充可压缩率梯度、LZ4 同算法
CPU/GPU 对比和真实数据集。

原始逐轮数据见 `runs.csv`，统计见 `summary.csv`。fio JSON 保存在本机
`results/local/high_concurrency_20260725T141003Z/`，未纳入仓库以控制体积。
