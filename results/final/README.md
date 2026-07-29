# V100 决赛实验结果索引

本目录只收录完成正确性校验、具有环境记录和原始 CSV/JSON 的结果。实验基于
Git HEAD `56a64bc25b2cf7e1eab6a5527b1fe8272af8b23c` 之后的工作区修复版；
由于尚未提交，关键源码与脚本的 SHA-256 见 `SOURCE_MANIFEST.sha256`。

硬件为 Tesla V100-SXM2-32GB（compute capability 7.0），驱动 570.181，
内核 5.15.0，fio 3.16。每个子目录的 `environment.txt` 是该实验的权威环境记录。

## 有效结果

| 目录 | 口径 | 主要结论 |
|---|---|---|
| `high_concurrency_warm_v100_20260729/` | 256 MiB，128 KiB，warm cache，fio threads，5 次 | SGLZ 187.9 MiB/s（1 线程）到 381.6 MiB/s（16 线程），32 线程回落至 348.8 MiB/s |
| `cold_cache_v100_20260729/` | `POSIX_FADV_DONTNEED` 后单遍，5 次 | Baseline 389.3、RAW 390.7、SGLZ 178.7 MiB/s |
| `ablation_v100_20260729/` | 256 MiB，5 次 | read-ahead 与 batch 各贡献约 11%；pinned memory 约 2.6%；io_uring/双流水线未测出收益 |
| `batch_size_v100_20260729/` | 1/2/4/8/16/32，5 次 | 4 块达到 183.2 MiB/s，之后无显著收益 |
| `compressibility_v100_20260729/` | 0/25/50/75/100%，5 次 | 0% 自动保留 RAW；真实空间占用随可压缩页比例从 134.2 MiB 降到 4.2 MiB |
| `backends_v100_20260729/` | 同一 `/usr/include` 归档，warm cache，5 次 | Baseline 9666、RAW 10519、SGLZ 107.8、批量 LZ4 81.0 MiB/s；LZ4 占用 38.1%，SGLZ 81.8% |
| `cpu_offload_4workers_v100_20260729/` | 4 个业务线程，5 次 | CPU/GPU 解压分别保留 87.5%/87.1% 业务吞吐，当前实现未证明 GPU 卸载优势 |
| `cpu_offload_1worker_v100_20260729/` | 1 个业务线程，3 次敏感性分析 | CPU/GPU 解压分别保留 50.1%/48.6%，结论同上 |

`break_even.csv` 根据 cold、headers 和可压缩率梯度的实测均值计算。所有已测
COMPRESSED 读取都慢于对应 Baseline，因此即使离线压缩成本按 0 计算，也不存在
正的读取次数性能 break-even；本轮只能证明空间收益，不能证明总时间收益。

## 结果边界

- warm-cache 与 cold-cache 分开解释；没有把 page cache 带宽当磁盘带宽。
- GPUC 紧凑块偏移不满足真正 `O_DIRECT` 对齐。Hook 对托管文件显式清除
  `O_DIRECT`，因此本轮不发布伪 O_DIRECT 成绩。
- `stat` 的格式长度包含稀疏逻辑区，不等于磁盘占用；空间结论使用
  `du -B1` 的 allocated bytes。
- `results/final/high_concurrency_v100_20260725/` 是保留的历史无效结果，
  其 README 已说明错误原因，不得用于决赛图表。
- 所有数值都是该单机软件栈的工程观测，不外推为生产级保证。
