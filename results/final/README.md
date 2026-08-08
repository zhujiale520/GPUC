# V100 与 RTX 4090 决赛实验结果索引

本目录只收录完成正确性校验、具有环境记录和原始 CSV/JSON 的结果。P0 新实验以
checkpoint `035e42b02a5a2a929c14c0de8fa1f1a5e86088b8` 为起点，随后加入对齐格式与
文档收口；未提交工作区的关键源码与脚本 SHA-256 见
`SOURCE_MANIFEST.sha256`。

V100 原始平台为 Tesla V100-SXM2-32GB（compute capability 7.0），驱动
570.181，内核 5.15.0，fio 3.16。RTX 4090 复测平台使用物理 GPU 1，
compute capability 8.9，驱动 565.57.01。每个子目录的 `environment.txt`
是该实验的权威环境记录；跨机器比较同时包含 CPU、内存、PCIe/SXM 和存储路径
差异，不能解释为只替换 GPU 的同机 A/B。

## RTX 4090 有效结果

完整缺口、配置优劣和 V100/4090 对比见
[`RTX4090_GAP_ANALYSIS_20260807.md`](RTX4090_GAP_ANALYSIS_20260807.md)。

| 目录 | 口径 | 主要结论 |
|---|---|---|
| `clean_deploy_rtx4090_gpu1_20260806T140003Z/` | 环境、CPU smoke、文档、GPU build/test | 五阶段全部 PASS |
| `offload_sensitivity_rtx4090_gpu1_20260806T140003Z/`、`offload_sensitivity_rtx4090_gpu1_pinned_20260806T144543Z/` | 1/2/4 GiB/s × 0/50/100%，pageable/pinned | pinned 的 4 GiB/s、100% 可压缩场景接近目标吞吐并显著降低业务争用 |
| `resource_rtx4090_gpu1_final_20260806T145935Z/` | 4 GiB/s、五轮资源画像 | GPU 比 CPU 多保留 13.05% 业务吞吐，解压路径 CPU 时间降低 96.4% |
| `h2d_*_rtx4090_gpu1_20260806T140003Z/` | H2D 合并、batch、workset、pageable/pinned 和设备映射 | pinned+coalesced 的 128 MiB workset 达 10674.3 MiB/s |
| `d2h_coalesce_rtx4090_gpu1_gap_20260807T143659Z/` | D2H 合并严格 A/B，各五轮 | 合并吞吐提高 41.4%，D2H 延迟降低 28.0% |
| `lz4_compress_sensitivity_rtx4090_gpu1_20260806T140003Z/`、`lz4_compress_fair_rtx4090_gpu1_gap_20260807T143659Z/` | 三档压缩率峰值与 CPU/GPU 公平压缩 | GPU batch 比 GPU serial 快 8.20 倍；同吞吐主机 CPU 比 CPU 路径低 29.8% |
| `fio_threads_rtx4090_gpu1_final_20260806T151148Z/`、`high_concurrency_rtx4090_gpu1_gap_20260807T143659Z/` | fio 正确性、退出稳定性和 1/4/8/16/32 jobs | 60/60 正确；128 KiB GPU Compressed 最佳为 16 jobs、584.8±43.4 MiB/s |
| `cold_cache_rtx4090_gpu1_gap_20260807T143659Z/`、`real_scan_rtx4090_gpu1_gap_20260807T143659Z/` | cold-cache 与真实日志/ELF 扫描 | GPU Compressed cold 读和真实扫描均无性能优势，作为适用边界保留 |
| `fault_recovery_rtx4090_gpu1_gap_20260807T143659Z/` | ENOSPC、SIGKILL、重启、fallback、`/dev/full` | 五项全部 PASS |
| `stability_1h_rtx4090_gpu1_final_20260806T151148Z/` | 512 MiB、128 KiB、4 jobs、持续一小时 | fio error=0，前后逻辑 SHA 一致 |
| `vdbench_rtx4090_gpu1_final_20260806T151148Z/` | Vdbench 5.04.07、4 线程、三类 workload、五轮 | 50/50 样本通过且逻辑 SHA 一致 |
| `batch_size_rtx4090_gpu1_gap_20260807T143659Z/`、`ablation_rtx4090_gpu1_gap_20260807T143659Z/` | batch=1/2/4/8/16/32 与七变体消融 | batch≥4 进入平台区；单独关闭 batch/readahead 分别下降 34.2%/30.9% |
| `sqlite_range_offload_rtx4090_gpu1_20260807T153922Z/` | SQLite range aggregate 与 4 GiB/s CPU/GPU 解压并行，各五轮 | GPU 相对 CPU QPS +11.21%、p99 -81.66%、解压进程 CPU 时间 -88.00%；仍低于无解压 baseline |
| `mmap_userfaultfd_rtx4090_gpu1_20260807T154208Z/`、`mmap_userfaultfd_threads8_rtx4090_gpu1_20260807T154304Z/` | 64/256 MiB、1/8 扫描线程、每组三路径五轮 | 60/60 mismatch=0；256 MiB 的 8 线程完整扫描没有优于单线程 |
| `lz4_adaptive_readahead_rtx4090_gpu1_20260807T154428Z/` | legacy/adaptive × 三 workload × 1/4 线程 × 五轮 | 60/60 error=0；4 KiB 随机读提高约 31.7–32.0 倍、p99 降约 96.9%，但仍低于 Baseline |
| `io_workload_matrix_rtx4090_gpu1_20260807T155002Z/` | 4/16/128 KiB、读/随机读/写/随机写/70:30、1/4 线程、Baseline QD 1/8/32 | 465/465 JSON、525 行指标、105 组 n=5，fio error=0；压缩读绝对性能仍为负 |
| `public_dataset_pg2600_rtx4090_gpu1_20260807T160500Z/` | 固定 SHA 的 Gutenberg #2600，压缩及冷/暖读各五轮 | 10/10 压缩、40/40 读取；LZ4 占用 68.76%，暖读 225.44 MiB/s，远低于 Baseline |
| `pcm_dram_128m_rtx4090_gpu1_20260808T011634Z/`、`pcm_dram_512m_rtx4090_gpu1_20260807T160755Z/` | Intel PCM 全系统 IMC、128/512 MiB、三场景各五轮 | 15/15 稳态样本均通过，但 CPU/GPU 均未达到请求吞吐，不能作为同 4 GiB/s DRAM A/B |
| `btrfs_zstd_rtx4090_gpu1_20260807T160755Z/`、`btrfs_real_cold_rtx4090_gpu1_20260807T160755Z/` | 安全 loop 的合成暖缓存与真实 corpus 文件级失效，各 30 样本 | 60/60、SHA 一致、zstd extent 已验证；真实 corpus Btrfs/GPUC 占用 31.46%/48.12% |

## V100 有效结果

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
| `lz4_adaptive_readahead_v100_20260730/` | 同一 LZ4 文件，固定 32-block 与请求感知预读严格 fio A/B，60 个样本 | 4 KiB 随机读提高 4.19–4.90 倍、p99 降低约 89.5%–91.0%；顺序读 CI 重叠 |
| `vdbench_lz4_adaptive_v100_20260730/` | 自适应 LZ4，Vdbench 4 线程、两类只读 workload、各五轮 | 10/10 通过；随机读 2.156 ±0.038 MB/s，顺序读 65.278 ±3.795 MB/s |
| `pcm_dram_v100_20260730/` | 第一版 16 MiB Intel PCM，各五轮 | cache-resident 方法学反例，不再作为主结论 |
| `pcm_dram_512m_v100_20260730/` | 512 MiB 轮转工作集、稳态 PCM，各五轮 | GPU/CPU 总 DRAM 带宽 4569.51/8745.46 MB/s，GPU 低 47.75%；D2H 写回仍约 4483.11 MB/s |
| `perf_offload_v100_20260730/` | 稳态进程及继承线程通用 perf 事件，各五轮 | GPU 相对 CPU 业务吞吐 +4.06%，instructions -2.43%，通用 cache misses -99.87% |
| `d2h_coalesce_v100_20260730/` | 连续 D2H 合并开关 A/B，各五轮 | D2H 8.522→2.669 ms，最大吞吐 1822.98→4895.29 MiB/s |
| `h2d_coalesce_v100_20260731/` | pinned staging单次H2D与逐block H2D严格A/B，各五轮 | 吞吐4805.13→5275.91 MiB/s（+9.80%），H2D 0.2713→0.0393 ms（-85.51%） |
| `lz4_compress_fair_v100_20260730/` | 相同输入/128 KiB/batch=32；CPU/GPU 同为 1024 MiB/s，旧 GPU serial 消融，各五轮 | 真 batch 至少快 18.34 倍；但同吞吐 GPU/CPU 主机成本 0.365/0.276 core，压缩侧没有 CPU 卸载收益 |
| `clean_deploy_cpu_20260730/` | 全新临时路径，CPU smoke 与 docs check | CPU-only 阶段记录；已由下一行完整 GPU 验收取代 |
| `clean_deploy_gpu_v100_20260731/` | 全新临时路径，随仓依赖，CPU/GPU build/test/docs | 五阶段全部 PASS，总耗时约 46 秒 |
| `real_scan_v100_20260731/` | 真实 dpkg status + Bash ELF，64 MiB，普通/CPU/GPU，各五轮 | 15/15 业务 hash/marker 一致；CPU/GPU 约 156.5/157.3 MiB/s，CI 重叠；空间占用 54.52% |
| `pcm_dram_compress_v100_20260731/` | CPU/GPU LZ4 压缩侧同输入、同 1024 MiB/s，PCM 各五轮 | GPU/CPU 总 DRAM 1809.39/1396.85 MB/s，GPU 高 29.53%；压缩侧无 CPU/DRAM/RSS 卸载收益 |
| `btrfs_zstd_v100_20260731/` | 高度可压缩合成日志型输入，ext4 plain、ext4+GPUC LZ4、Btrfs zstd:3，暖页缓存，各五轮 | 30/30 fio/SHA 通过；Btrfs/GPUC 占用 3.125%/6.284%；性能只代表暖缓存路径，不是 NVMe |
| `offload_sensitivity_v100_20260731/` | 1/2/4 GiB/s × 0/50/100% 可压缩页，CPU/GPU 同核竞争，各五轮 | 95 个样本；业务收益随吞吐/压缩率增强，4 GiB/s 中低压缩率组进入饱和 |
| `lz4_compress_sensitivity_v100_20260731/` | CPU/GPU batch 不限速压缩峰值，三档压缩率，各五轮 | GPU 423–1301 MiB/s，仅为单核 CPU 的 7.3%–16.6%；压缩侧负结论保持 |
| `sqlite_direct_read_v100_20260731/` | **历史无效**：runner误用只生成SGLZ的CPU daemon | 原329.86/21.79 QPS不得标作LZ4或用于图表；README已记录错误来源 |
| `sqlite_direct_fixed32_v100_20260731/` | **历史无效**：继承相同fixture算法错误 | 仅保留审计，不进入结论 |
| `sqlite_direct_lz4_gpu_only_v100_20260731/` | 真实LZ4、严格GPU-only、SQLite单worker，各五轮 | GPU-only 55.67 QPS、p99 24.47 ms，仍为负结果 |
| `sqlite_direct_lz4_hybrid_v100_20260731/` | 真实LZ4、单block CPU分流、相同SQLite口径，各五轮 | 相对GPU-only QPS +94.58%、p99 -52.52%；仍比普通文件慢99%以上 |
| `vdbench_lz4_gpu_only_v100_20260731/` | 128 MiB真实LZ4、4线程4 KiB随机读、GPU-only，各五轮 | 2.076±0.136 MB/s、平均响应6.947 ms |
| `vdbench_lz4_hybrid_v100_20260731/` | 相同fixture，单block CPU分流，各五轮 | 12.239±0.263 MB/s（5.89倍），平均响应0.819 ms；仍低于Baseline |
| `pcm_dram_sensitivity_v100_20260731/` | 512 MiB工作集，1024:0%、2048:50%、4096:100%，whole-system PCM，各五轮 | GPU/CPU总DRAM差从−0.11%扩大到−47.42%，证明DRAM收益强依赖吞吐和压缩率 |
| `btrfs_real_cold_v100_20260731/` | dpkg status+Bash真实corpus，fio文件级`invalidate=1`，三路径各五轮 | Btrfs/GPUC空间占用36.36%/54.61%；GPUC顺序/随机均落后；loop结果不是NVMe成绩 |

`break_even.csv` 根据 cold、headers 和可压缩率梯度的实测均值计算。所有已测
COMPRESSED 读取都慢于对应 Baseline，因此即使离线压缩成本按 0 计算，也不存在
正的读取次数性能 break-even；本轮只能证明空间收益，不能证明总时间收益。

## 结果边界

- warm-cache 与 cold-cache 分开解释；没有把 page cache 带宽当磁盘带宽。
- 新版 COMPRESSED 格式支持 4 KiB 对齐 direct I/O；旧格式、RAW 和 INLINE 仍会
  清除 `O_DIRECT`。正式 direct 结果来自 SATA/ext4，不是 NVMe。
- 512 MiB稳态Intel PCM代表组已完成；GPU相对CPU总DRAM差随吞吐/可压缩率
  从−0.11%扩大到−47.42%，不能只展示最高档并外推；GPU RSS高5.80%–8.92%，
  仍不能主张容量节省或消除写回。
- RTX 4090 PCM 的 128/512 MiB 组虽然各完成 15/15 稳态样本，但 PCM 包裹执行
  下 CPU/GPU 实际吞吐分别只有 3652.6/1392.6 和 3404.1/1314.1 MiB/s。
  两条路径分母不同，不能把总 IMC 数字直接解释为同吞吐降幅；同吞吐 DRAM 主证据
  仍使用 V100 正式组。
- cycles、instructions 和通用 cache 事件已完成；精确型号化
  `LLC-load-misses` 在本机不受支持，不能用通用 cache-misses 冒充。
- `stat` 的格式长度包含稀疏逻辑区，不等于磁盘占用；空间结论使用
  `du -B1` 的 allocated bytes。
- Btrfs合成暖缓存基线以`compsize -b`和`filefrag encoded`验证extent压缩；
  真实corpus另有`invalidate=1`文件页缓存失效结果。两者都在loop上，均不能当作
  介质或NVMe吞吐。
- PG2600 暖态 fio 统一计时 25 个完整 128 KiB block；冷读仍校验完整文件。
  这是为适配 fio 3.28 的非整块尾部行为，不应与 V100 的 fio 3.16 尾块语义
  混作严格跨机性能排名。
- SQLite直接读取证明只读兼容性，不证明性能收益；旧目录算法标签错误已作废。
  真实LZ4混合分流虽比GPU-only快94.58%，但实际使用了CPU且仍比普通文件慢99%以上。
- `results/final/high_concurrency_v100_20260725/` 是保留的历史无效结果，
  其 README 已说明错误原因，不得用于决赛图表。
- 所有数值都是该单机软件栈的工程观测，不外推为生产级保证。
- V100 正式长稳目录实际执行 10 分钟；RTX 4090 已完成一小时持续读取。真实 GPU
  reset、掉电和更长时间压力仍需要隔离且具有管理员权限的机器。
