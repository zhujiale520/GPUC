# V100 决赛实验结果索引

本目录只收录完成正确性校验、具有环境记录和原始 CSV/JSON 的结果。P0 新实验以
checkpoint `035e42b02a5a2a929c14c0de8fa1f1a5e86088b8` 为起点，随后加入对齐格式与
文档收口；未提交工作区的关键源码与脚本 SHA-256 见
`SOURCE_MANIFEST.sha256`。

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
| `backends_v100_20260729/` | 优化前历史正式值 | LZ4 81.0 MiB/s；用于和新 worker 版本做整体前后对比 |
| `backends_worker_batch32_v100_20260729/` | 长期 worker + 持久 buffer + 32-block read-ahead，5 次 | LZ4 178.6 ±14.6 MiB/s，为旧正式值约 2.21 倍；仍远慢于 Baseline |
| `lz4_worker_micro_v100_20260729/` | 同一内存中 LZ4 数据，CPU/GPU 各 5 次；4 caller 并发校验 | GPU 5456.1 ±87.7 MiB/s；CPU 10900.6 ±399.4 MiB/s，GPU 绝对吞吐仍较低 |
| `cpu_offload_fixed4g_samecore_v100_20260729/` | CPU/GPU 都限速约 4096 MiB/s，与业务争用 core 0，5 次 | CPU/GPU 分别保留 89.85%/97.17% 业务吞吐，95% CI 不重叠 |
| `cpu_offload_fixed4g_isolated_v100_20260729/` | 同吞吐，解压隔离到 core 4，5 次 | GPU 额外主机 CPU 约 0.403 core，CPU 为 0.566 core，降低约 28.8% |
| `sqlite_range_offload_fixed4g_samecore_v100_20260729/` | SQLite range aggregate + 同吞吐解压，5 次 | GPU 比 CPU QPS 高约 7.3%，p99 低约 50.5%；GPU p99 仍高于无解压 baseline |
| `odirect_aligned_v100_20260729/` | 512 MiB、128 KiB、15 秒、`direct=1` | O_DIRECT 标志保留、内容正确、0 error、62.9 MiB/s；设备为 SATA/ext4 |
| `p0_resource_capability_v100_20260729/` | 资源计数器与存储设备审计 | 记录 CPU/RSS/fault/context/profile 与原始 DRAM/NVMe 环境限制；DRAM 后续已由 PCM 补齐 |
| `mmap_userfaultfd_v100_20260729/` | 64/256 MiB，单线程逐页 pattern，5 次 | 256 MiB `mmap()` 0.215±0.011 ms，首次 fault 146.502±3.836 ms，mismatch=0 |
| `mmap_userfaultfd_threads8_v100_20260729/` | 同输入，8 扫描线程，5 次 | 256 MiB 完整扫描 5376.3±159.1 ms，无稳定线性扩展 |
| `fault_recovery_v100_20260729/` | ENOSPC、SIGKILL、重启、GPU 不可见、`/dev/full` | 五项全部 PASS，原 RAW/逻辑 SHA 保持 |
| `stability_10m_v100_20260729/` | 256 MiB、128 KiB、持续 600 秒 | fio error=0，600 个带宽样本，前后逻辑 SHA 一致 |
| `coverage_cpu_20260729/` | GCC/gcov CPU Hook/Daemon/SGLZ/LZ4 | Hook 行 41.38%、分支执行 50.06%；CI 最低门槛 35% |
| `vdbench_v100_20260730/` | Vdbench 5.04.07，256 MiB，4 线程，三类 workload，各五轮 | 50/50 样本通过且 SHA 一致；共享 fd 正确性已修复，压缩随机读仍是明确短板 |
| `pcm_dram_v100_20260730/` | 第一版 16 MiB Intel PCM，各五轮 | cache-resident 方法学反例，不再作为主结论 |
| `pcm_dram_512m_v100_20260730/` | 512 MiB 轮转工作集、稳态 PCM，各五轮 | GPU/CPU 总 DRAM 带宽 4569.51/8745.46 MB/s，GPU 低 47.75%；D2H 写回仍约 4483.11 MB/s |
| `perf_offload_v100_20260730/` | 稳态进程及继承线程通用 perf 事件，各五轮 | GPU 相对 CPU 业务吞吐 +4.06%，instructions -2.43%，通用 cache misses -99.87% |
| `d2h_coalesce_v100_20260730/` | 连续 D2H 合并开关 A/B，各五轮 | D2H 8.522→2.669 ms，最大吞吐 1822.98→4895.29 MiB/s |

`break_even.csv` 根据 cold、headers 和可压缩率梯度的实测均值计算。所有已测
COMPRESSED 读取都慢于对应 Baseline，因此即使离线压缩成本按 0 计算，也不存在
正的读取次数性能 break-even；本轮只能证明空间收益，不能证明总时间收益。

## 结果边界

- warm-cache 与 cold-cache 分开解释；没有把 page cache 带宽当磁盘带宽。
- 新版 COMPRESSED 格式支持 4 KiB 对齐 direct I/O；旧格式、RAW 和 INLINE 仍会
  清除 `O_DIRECT`。正式 direct 结果来自 SATA/ext4，不是 NVMe。
- 512 MiB 稳态 Intel PCM 已完成；GPU 总 DRAM bandwidth 比 CPU 低约
  47.75%，但 D2H 写带宽高约 3.56%、最大 RSS 高约 8.94%，只能主张总带宽
  下降，不能主张容量节省或消除写回。
- cycles、instructions 和通用 cache 事件已完成；精确型号化
  `LLC-load-misses` 在本机不受支持，不能用通用 cache-misses 冒充。
- `stat` 的格式长度包含稀疏逻辑区，不等于磁盘占用；空间结论使用
  `du -B1` 的 allocated bytes。
- `results/final/high_concurrency_v100_20260725/` 是保留的历史无效结果，
  其 README 已说明错误原因，不得用于决赛图表。
- 所有数值都是该单机软件栈的工程观测，不外推为生产级保证。
- 长稳脚本默认 1 小时，但当前正式目录实际执行 10 分钟；真实 GPU reset、掉电和
  数小时压力仍需要隔离且具有管理员权限的机器。
