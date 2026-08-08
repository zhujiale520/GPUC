# RTX 4090 实验闭环与补跑结论

## 范围与口径

- 设备：物理 GPU 1，NVIDIA GeForce RTX 4090，驱动 565.57.01，compute
  capability 8.9。
- 核心批次：`rtx4090_gpu1_final_20260806T151148Z`；缺口批次：
  `rtx4090_gpu1_gap_20260807T143659Z`；最终补齐批次为 2026-08-07 至
  2026-08-08 的 SQLite、mmap、预读、I/O 矩阵、PG2600、PCM 和 Btrfs。
- V100/4090 是整机对比，不是只替换 GPU 的同机 A/B。CPU、内存、PCIe/SXM
  拓扑、内核、fio 版本和存储路径都可能影响结果。
- 所有正向与负向结果均保留；压缩读取没有超过普通文件，不把 page cache 或
  loop backing file 数字包装成 NVMe 性能。

## 已完成的 4090 证据

| 实验 | 验收 | 4090 主要结论 |
|---|---:|---|
| 核心卸载与资源画像 | 各 5 轮 | 4 GiB/s 高可压缩压力下，GPU 比 CPU 多保留 13.05% 业务吞吐；解压路径 CPU 时间降低 96.4% |
| SQLite 并行业务 | 15/15 | GPU 相对 CPU QPS 提高 11.21%，p99 降低 81.66%，解压进程 CPU 时间降低 88.00%；仍比无解压 baseline 低 5.14% |
| H2D/D2H、batch、消融 | 全部 5 轮 | pinned+coalesced H2D 达 10674.3 MiB/s；D2H 合并吞吐提高 41.4%；GPU batch 比 serial 快 8.20 倍 |
| fio 多线程与完整矩阵 | 60/60；465/465 | 多线程退出、CRC/SHA 和 fio error 全通过；完整矩阵为 465 个 JSON、525 行指标、105 组 n=5，0 error |
| LZ4 自适应预读 | 60/60 | 4 KiB 随机读相对 legacy 提高 31.71 倍（1 线程）和 31.97 倍（4 线程），p99 下降约 96.9%；仍远低于 Baseline |
| mmap/userfaultfd | 60/60 | 256 MiB 单线程 `mmap()` 0.311 ms、首次 fault 165.9 ms、扫描 2305.6 ms；8 线程扫描 2323.1 ms，无扩展收益，mismatch=0 |
| Vdbench | 50/50 | 5.04.07、4 线程、三类 workload、五轮通过，逻辑 SHA 一致 |
| 一小时稳定性与故障恢复 | 1 小时；5/5 | 持续读 fio error=0、前后 SHA 一致；ENOSPC、SIGKILL、重启、GPU fallback、`/dev/full` 全通过 |
| PG2600 公共数据集 | 压缩 10/10；读取 40/40 | LZ4 占用 68.76%，暖读 225.44 MiB/s，普通文件 12558.37 MiB/s；SGLZ 正确回退 RAW |
| Btrfs 安全 loop | 60/60 | 合成/真实 corpus 各 30/30、SHA 一致、zstd extent 已验证；真实 corpus Btrfs/GPUC 占用 31.46%/48.12% |
| PCM DRAM | 128/512 MiB 各 15/15 | 稳态区间解析已修复；但 4 GiB/s 请求下 CPU/GPU 仅达 3652.6/1392.6（128 MiB）和 3404.1/1314.1 MiB/s（512 MiB），不能作为同吞吐 DRAM A/B |
| cold-cache、真实扫描、低压缩率、压缩峰值 | 全部 5 轮 | 均未证明压缩读取或压缩侧超过 CPU/Baseline，作为适用边界保留 |

PG2600 的逻辑长度 3359610 B 不是 128 KiB 整数倍。fio 3.28 对 Hook 最后一个
不完整块报 `full resid`，正式暖读统一计时前 3276800 B（25 个完整块），冷读仍
完整读取并校验全文件 SHA；失败的首轮目录未进入 `results/final/`。

## 哪些实验效果最好

1. **主结论**：页锁定的 4 GiB/s、100% 可压缩解压场景；它直接证明释放主机
   CPU 后能保留更多业务吞吐。
2. **真实业务补强**：SQLite 并行业务中，GPU 相对 CPU 路径 QPS +11.21%、
   p99 -81.66%。GPU RSS 为 130840 KiB，明显高于 CPU 的 38016 KiB，因此不能
   同时宣称主机内存容量降低。
3. **最显著内部优化**：请求感知预读让 4 KiB 随机压缩读提高约 32 倍；这是相对
   legacy 的内部 A/B，不代表超过普通文件。
4. **最佳并发点**：128 KiB GPU Compressed 为 16 jobs，584.8±43.4 MiB/s；
   32 jobs 回落。Hook batch=4 已进入平台区，不能证明继续增大必然更好。
5. **稳定性证据**：一小时持续读、fio 60/60、Vdbench 50/50、完整矩阵 465/465
   和故障恢复 5/5 共同构成功能—性能—稳定性闭环。

## PCM 与 Btrfs 的解释边界

- 4090 PCM 两个工作集均完整取得 15 个正式样本，且只汇总应用稳态内的完整
  1 秒区间；时区错误已经修复。
- PCM 包裹执行时 CPU/GPU 都未达到请求吞吐，GPU 饱和更早。可以报告各自实际
  吞吐和总 IMC bandwidth，但不能用 2237.9 与 6977.4 MB/s 直接声称 GPU 在
  “同 4 GiB/s”下降低 67.9%，因为分母不同。同吞吐 DRAM 主证据仍来自 V100。
- 512 MiB PCM 的 `SOURCE_MANIFEST.sha256` 仅有 `pcm_dram_offload.sh` 与当前
  文件不一致，原因是该批次结束后只新增了 `pin_workset` 环境记录；128 MiB 批次
  与当前脚本清单完全一致，算法和测试二进制未改变。
- Btrfs 只格式化脚本自建并验证 backing file 的 loop device。合成数据上
  Btrfs/GPUC 占用 3.125%/6.283%；真实 corpus 为 31.46%/48.12%。
- Btrfs 的 warm-cache 或 `invalidate=1` 结果受 page cache、loop 和系统 CPU
  影响，不是介质吞吐；正式 NVMe 结论仍缺失。

## V100 与 4090 的同参数观察

- 4090 GPU LZ4 100% 可压缩峰值 1656.1 MiB/s，比 V100 的 1300.6 MiB/s 高
  27.3%；GPU serial 从 55.8 提高到 124.6 MiB/s。
- SGLZ fio 4 线程、128 KiB 从 V100 173.2 提高到 4090 527.6 MiB/s；Vdbench
  LZ4 顺序读从 44.48 提高到 137.50 MiB/s，但两者仍低于普通文件。
- D2H coalesced 吞吐 4090 为 2199.3 MiB/s、V100 为 4895.3 MiB/s；这反映整机
  PCIe/SXM 和主机路径差异，不能解释为单纯 GPU 算力排名。
- V100 自适应预读的 4 KiB 随机读提升 4.19–4.90 倍，4090 为约 32 倍；两机
  legacy 基线和软件栈不同，只能分别解释各自内部 A/B。

## 仍然缺失、但不能在当前机器补齐

- 鲲鹏 920/AArch64 实测；
- 赛题指定的 RTX 3060/4060/5060（4090 只能作为跨代补充）；
- 归属明确、允许写入的独占 NVMe 介质测试；
- ZFS/DM 真正后端、非 NVIDIA GPU 后端；
- RAPL/IPMI/外部功率计的 CPU package 与整机能效。

## 本轮新增结果目录

- `sqlite_range_offload_rtx4090_gpu1_20260807T153922Z/`
- `mmap_userfaultfd_rtx4090_gpu1_20260807T154208Z/`
- `mmap_userfaultfd_threads8_rtx4090_gpu1_20260807T154304Z/`
- `lz4_adaptive_readahead_rtx4090_gpu1_20260807T154428Z/`
- `io_workload_matrix_rtx4090_gpu1_20260807T155002Z/`
- `public_dataset_pg2600_rtx4090_gpu1_20260807T160500Z/`
- `pcm_dram_512m_rtx4090_gpu1_20260807T160755Z/`
- `pcm_dram_128m_rtx4090_gpu1_20260808T011634Z/`
- `btrfs_zstd_rtx4090_gpu1_20260807T160755Z/`
- `btrfs_real_cold_rtx4090_gpu1_20260807T160755Z/`
