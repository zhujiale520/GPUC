# RTX 4090 实验缺口与补跑结论

## 范围

- 设备：物理 GPU 1，NVIDIA GeForce RTX 4090，驱动 565.57.01。
- 已有最终标签：`rtx4090_gpu1_final_20260806T151148Z`。
- 本轮补跑标签：`rtx4090_gpu1_gap_20260807T143659Z`。
- 不重跑：H2D A/B、页锁定矩阵、offload sensitivity、资源画像、fio
  多线程回归、一小时稳定性和 Vdbench 正式五轮。
- V100/4090 是整机对比，不是只替换 GPU 的同机对比。CPU、内存、PCIe/SXM
  拓扑和存储路径都可能影响结果。

## 本轮补跑

| 实验 | 样本 | 4090 主要结论 |
|---|---:|---|
| D2H 合并 A/B | 10/10 | 合并吞吐 2199.3 MiB/s，比 legacy 高 41.4%；D2H 延迟低 28.0% |
| LZ4 公平压缩 | 15/15 | GPU batch 比 GPU serial 快 8.20 倍；同为约 1 GiB/s 时，GPU batch 的主机 CPU 比 CPU 路径低 29.8% |
| 128 KiB 并发扩展 | 75/75 | GPU Compressed 最佳为 16 jobs：584.8 ±43.4 MiB/s，是 1 job 的 4.15 倍；32 jobs 退化到 542.1 MiB/s |
| cold-cache 三路径 | 15/15 | Baseline 518.4、Hook RAW 512.0、GPU Compressed 144.9 MiB/s |
| 真实日志/ELF 扫描 | 15/15 | CPU 166.114、GPU 166.079 MiB/s，差异仅 -0.02%，GPU 没有业务吞吐优势 |
| 故障恢复 | 5/5 | ENOSPC、SIGKILL、残留临时文件恢复、GPU 不可见 fallback、`/dev/full` 全通过 |
| Hook 批大小 | 30/30 | batch=32 均值最高 141.7 MiB/s，但与 batch=4 的 140.6 MiB/s 的 95% CI 重叠；batch>=4 进入平台区 |
| Hook 消融 | 35/35 | 单独关闭 batch/readahead 分别下降 34.2%/30.9%；关闭 pinned 下降 5.3%；io_uring 和 pipeline 在此场景贡献不显著 |

消融中的 `minimal` 比 `full` 高 10.3%，与单项消融方向相反。这是宏组合触发的
路径交互，不能把各项 drop 当作可加和的独立贡献，也不能据此宣称“全部优化无效”。

## 4090 上效果最好的配置

1. 核心业务结论仍是页锁定的 4 GiB/s、100% 可压缩场景：GPU 相对 CPU
   多保留 13.05% 业务吞吐，并减少 96.4% 解压路径 CPU 时间。
2. 传输侧最强配置是 pinned + coalesced。128 MiB workset 下达到
   10674.3 MiB/s，是 pageable + coalesced 的 4.27 倍。
3. 压缩侧必须使用 GPU batch：相对 GPU serial 为 8.20 倍加速。
4. 128 KiB 压缩读取并发最佳点是 16 jobs；32 jobs 没有继续收益。
5. Hook 读取批大小选择 4 或 32 都合理；当前数据不足以证明 32 显著优于 4。

## V100 与 4090 的同参数观察

- 4090 的 GPU LZ4 压缩峰值更高：100% 可压缩时 1656.1 MiB/s，相对 V100
  的 1300.6 MiB/s 高 27.3%。
- GPU serial 压缩从 V100 的 55.8 提高到 4090 的 124.6 MiB/s，提升 123.2%。
- SGLZ fio 4 线程、128 KiB 从 V100 的 173.2 提高到 4090 的
  527.6 MiB/s，提升 204.6%。
- 高并发 GPU Compressed 在 4/8/16/32 jobs 上比 V100 高约
  60.4%/54.5%/53.2%/55.4%；单 job 反而低 25.1%。
- Vdbench LZ4 顺序读从 V100 的 44.48 提高到 4090 的 137.50 MiB/s，
  提升 209.1%。这仍远低于 Baseline，属于适用边界，不作为普遍加速证据。
- D2H coalesced 吞吐 4090 为 2199.3 MiB/s，V100 为 4895.3 MiB/s；
  4090 整机低 55.1%。这更像 PCIe/SXM 与主机路径差异，不能解释为 GPU
  算力不足。
- cold-cache GPU Compressed 在 4090 上比 V100 低 18.9%。
- 真实扫描的 V100 和 4090 corpus SHA 不同，只能比较各机器内部的
  CPU/GPU 相对结果，不能做严格硬件排名。

## 仍缺的数据

### 优先级高

1. **PCM DRAM 带宽**：当前 `third_party/manual/pcm/build/bin/pcm-memory`
   不存在。这是“是否降低主机 DRAM 压力”唯一缺失的直接证据。
2. **SQLite 直接读取压缩对象**：可补数据库应用层 QPS 与 p95/p99，但不影响
   当前功能、稳定性和核心卸载结论。
3. **mmap/userfaultfd**：V100 有 1/8 线程结果，4090 尚未复跑；仅在答辩需要
   强调 mmap 兼容性时优先。

### 可选

- 公共数据集 PG2600：补外部有效性；当前机器没有发现既有 dataset。
- `perf` cycles/cache-miss：补 CPU 微架构解释，需要 perf 权限。
- Btrfs、完整 93 点 I/O 矩阵、O_DIRECT 边界：成本较高，且大部分不改变
  4090 核心结论，不建议为了“目录齐全”机械重跑。

## 结果目录

- `results/final/d2h_coalesce_rtx4090_gpu1_gap_20260807T143659Z`
- `results/final/lz4_compress_fair_rtx4090_gpu1_gap_20260807T143659Z`
- `results/final/high_concurrency_rtx4090_gpu1_gap_20260807T143659Z`
- `results/final/cold_cache_rtx4090_gpu1_gap_20260807T143659Z`
- `results/final/real_scan_rtx4090_gpu1_gap_20260807T143659Z`
- `results/final/fault_recovery_rtx4090_gpu1_gap_20260807T143659Z`
- `results/final/batch_size_rtx4090_gpu1_gap_20260807T143659Z`
- `results/final/ablation_rtx4090_gpu1_gap_20260807T143659Z`
