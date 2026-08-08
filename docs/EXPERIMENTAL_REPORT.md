# GPUC 决赛实验报告

> 更新日期：2026-08-08
> 本报告只采用 `results/final/` 中可复核的结果。此前报告中的 jobs=32
> “99.8%”、混合缓存口径和未重复实验均已撤下；2026-07-29 已完成对齐格式，
> 新的 O_DIRECT 结果与旧的伪 O_DIRECT 结果严格区分。

## 1. 项目与实验问题

GPUC 使用 `LD_PRELOAD` 拦截一组 libc 文件接口，在 RAW 文件关闭后由 daemon
离线压缩，并在读取 COMPRESSED 文件时用 GPU 解压。它适用于动态链接、通过已拦截
接口访问普通文件的程序，不覆盖静态链接、直接 syscall、应用自行提交的 io_uring
或任意内核文件路径。

本轮实验回答八个问题：

1. 文件语义和并发替换是否正确；
2. warm/cold cache 下真实吞吐如何；
3. read-ahead、batch、pinned memory 等优化是否有贡献；
4. 长期 GPU worker 是否能释放 CPU 并提高并行业务吞吐；
5. SQLite 真实业务的 QPS 和尾延迟是否受益；
6. 对齐压缩格式能否保留真正的 `O_DIRECT`。
7. CPU/GPU 压缩侧在同一吞吐下是否也能降低主机 CPU；
8. 逐块同步改成真正 nvCOMP batch 后，压缩路径改善多少。

## 2. 环境与方法

- GPU：Tesla V100-SXM2-32GB，compute capability 7.0；
- 驱动：570.181；内核：Linux 5.15.0；fio：3.16；
- 补充平台：物理 GPU 1，RTX 4090 24 GB，compute capability 8.9，驱动
  565.57.01，Linux 6.8.0，fio 3.28；跨平台数字按整机结果解释；
- 核心 fio 实验使用 128 KiB 顺序读、`direct=0`；
- 每个正式场景通常重复 5 次，报告 mean、sample stddev 和 95% CI；
- Baseline、Hook RAW、SGLZ/LZ4 使用独立文件且逻辑内容相同；
- 每轮保存 header state、算法、SHA-256、格式长度和 allocated bytes；
- warm-cache 在计时前完整逻辑预读；cold-cache 在底层 inode 上执行
  `POSIX_FADV_DONTNEED` 后只读一遍。

新版 COMPRESSED 格式把 header、每个 block offset 和物理读取跨度对齐到
4 KiB，并在 block entry 中记录 padded span。旧格式仍兼容，但 Hook 只对新版
对齐格式保留 `O_DIRECT`，对 RAW、INLINE 和旧 COMPRESSED 格式清除该标志。

原始数据、fio JSON、环境与脚本索引见
[`../results/final/README.md`](../results/final/README.md)。

## 3. 正确性与工程修复

最终回归通过：

- GPU unit/integration、混合块、INLINE、cp/dd；
- nvCOMP LZ4 与 SGLZ 压缩后 SHA-256 回读；
- RAW 的 `writev/pwrite/O_APPEND/ftruncate/dup` 语义；
- COMPRESSED 写入、截断和破坏性修改统一返回 `EROFS`；
- 白名单 rename 使用同目录临时文件、fsync、原子 rename，并保留
  mode/owner/mtime/xattr；
- daemon 原子替换期间，同一路径的已打开读者和重复 reopen 读者保持一致；
- 损坏 header、block table、非法 offset 和超大字段在 open 时拒绝；
- io_uring 全局 ring 的提交/完成队列加事务锁，并按 `user_data` 归属 CQE；
- CUDA stream 池扩为 64，覆盖 32 个双流水线线程，避免 stream 重用覆盖；
- nvCOMP LZ4 改为长期 worker、持久化 CUDA stream/event/device buffer 和
  pinned host buffer，不再每次请求 `cudaMalloc/cudaFree`；
- 对齐格式的 `O_DIRECT` 标志保留、混合压缩/RAW block 和逻辑内容校验通过；
- ASan/UBSan CPU Hook、shell 语法和 Markdown 本地链接检查通过。

mmap 默认通过 userfaultfd 捕获 missing-page fault，以 128 KiB GPUC block 为
填充单位；不支持该机制的内核自动回退到同步完整填充。实验分别记录 `mmap()`
返回、首次 fault 和完整扫描，避免把后移的解压成本描述成消失。

## 4. 主要结果

### 4.1 warm-cache 并发扩展

| 线程 | Baseline MiB/s | Hook RAW MiB/s | SGLZ MiB/s |
|---:|---:|---:|---:|
| 1 | 7539.8 ± 57.2 | 8476.2 ± 135.9 | 187.9 ± 0.5 |
| 4 | 22083.2 ± 133.0 | 23996.7 ± 143.2 | 344.8 ± 6.2 |
| 8 | 38712.8 ± 182.4 | 42356.9 ± 178.3 | 349.1 ± 6.6 |
| 16 | 66162.5 ± 1676.0 | 70080.2 ± 700.2 | 381.6 ± 6.2 |
| 32 | 59153.2 ± 2468.5 | 83950.2 ± 11475.4 | 348.8 ± 5.4 |

SGLZ 从 1 到 16 线程提升约 2.03 倍，32 线程回落，说明高并发已受 GPU
提交、同步和共享资源争用限制。Baseline/RAW 是内存缓存吞吐，不代表磁盘带宽。

### 4.2 cold-cache 单遍

| 路径 | mean MiB/s | 95% CI |
|---|---:|---:|
| Baseline | 389.3 | ±21.8 |
| Hook RAW | 390.7 | ±1.3 |
| SGLZ | 178.7 | ±5.6 |

在这台机器上，减少物理读取量仍不足以抵消 GPU 解压和传输成本；本项目不能声称
顺序冷读普遍快于原文件。

### 4.3 消融

| 变体 | mean MiB/s | 相对 full |
|---|---:|---:|
| full | 182.0 | 基准 |
| no read-ahead | 161.8 | -11.10% |
| no batch | 162.0 | -10.99% |
| no pinned | 177.3 | -2.61% |
| no io_uring | 182.4 | +0.23% |
| no pipeline | 182.8 | +0.43% |
| minimal | 158.0 | -13.20% |

本场景只证实 read-ahead、batch 和 pinned memory 的贡献。io_uring 和双流水线
没有超出噪声的收益，不能作为确定加速结论。

### 4.4 批大小

| blocks/batch | 1 | 2 | 4 | 8 | 16 | 32 |
|---:|---:|---:|---:|---:|---:|---:|
| MiB/s | 161.9 | 177.8 | **183.2** | 182.9 | 183.1 | 182.3 |

SGLZ 默认批大小由 16 调整为 4；4 之后没有显著收益，并可降低每线程缓冲占用。

### 4.5 同一文本数据的四路径

输入为固定顺序、固定 mtime/owner 的 `/usr/include` tar，逻辑大小 37,703,680 B。

| 路径 | allocated bytes | 占原始比例 | warm mean MiB/s |
|---|---:|---:|---:|
| Baseline | 37,703,680 | 100.0% | 11000.2 ± 49.4 |
| Hook RAW | 37,707,776 | 100.0% | 14476.8 ± 199.8 |
| SGLZ | 30,851,072 | 81.8% | 44.2 ± 1.8 |
| nvCOMP LZ4 | 14,356,480 | 38.1% | 178.6 ± 14.6 |

LZ4 读路径在长期 worker、持久化 buffer 和 32-block read-ahead 后，由上一轮
正式值 81.0 提升到 178.6 MiB/s，约为 2.21 倍。该提升不能拆分归因给单一优化。
SGLZ 本轮只有 44.2 MiB/s，说明不同后端的同步策略仍需继续剖析。两种压缩读取
都远慢于 warm Baseline，因此文件读取主结论仍为负。

独立内存微基准中，GPU nvCOMP LZ4 为 5456.1 ±87.7 MiB/s，CPU liblz4 为
10900.6 ±399.4 MiB/s；4 个 caller 并发提交的数据一致性也通过。持久 worker
已显著降低 GPU 路径开销，但没有使 GPU 绝对吞吐超过此 Xeon CPU；固定
4096 MiB/s 的业务实验仍低于两者能力上限。

### 4.6 可压缩率梯度

128 MiB 输入中，可压缩 4 KiB 页比例从 0% 增加到 100%：

| 可压缩页 | 状态 | allocated bytes | GPUC warm MiB/s |
|---:|---|---:|---:|
| 0% | RAW | 134,221,824 | 7893.8 ± 129.8 |
| 25% | COMPRESSED | 103,522,304 | 234.1 ± 0.8 |
| 50% | COMPRESSED | 71,114,752 | 202.9 ± 1.2 |
| 75% | COMPRESSED | 37,724,160 | 175.3 ± 0.8 |
| 100% | COMPRESSED | 4,239,360 | 182.7 ± 1.4 |

0% 数据被 85% 阈值正确保留为 RAW。格式 `stat` 长度包含稀疏区，空间结论必须
使用 allocated bytes。

### 4.7 同吞吐 CPU 卸载

为避免“CPU 路径处理得更多所以占 CPU 更多”的混淆，CPU 与 GPU 都限速到约
4096 MiB/s、运行 5 秒并重复 5 次。

| 场景 | CPU LZ4 | GPU LZ4 | 解释 |
|---|---:|---:|---|
| 解压与业务争用 core 0：业务保留率 | 89.85% | **97.17%** | GPU 比 CPU 多保留 7.32 个百分点 |
| 解压隔离到 core 4：额外主机 CPU core | 0.566 | **0.403** | GPU 主机 CPU 成本低约 28.8% |
| 隔离场景最大 RSS | 148260.8 KiB | 150420.8 KiB | GPU 多约 2.1 MiB，不是 DRAM 容量节省 |

这组结果证明的是：在固定约 4 GiB/s 的 LZ4 任务下，长期 GPU worker 可减少主机
CPU 时间，并在共享核心争用时保护更多业务吞吐。它不证明 GPU 的绝对解压吞吐
超过 CPU，也不证明主机 DRAM 容量下降。

旧实现每批提交 128 次 D2H。`results/final/d2h_coalesce_v100_20260730/`
在 512 MiB 轮转工作集上对旧方式和连续区间合并各做五轮 A/B：

| D2H 方式 | 最大吞吐 MiB/s | D2H ms/批 | 请求总计 ms/批 |
|---|---:|---:|---:|
| 每块一次拷贝 | 1822.98 ±301.36 | 8.522 ±1.502 | 9.002 ±1.526 |
| 连续区间合并 | **4895.29 ±145.46** | **2.669 ±0.079** | **3.158 ±0.092** |

合并后 D2H 降低约 68.7%，最大吞吐提高约 168.5%。该结果只归因于同一实现开关
的 A/B；正式固定 4 GiB/s 资源实验默认启用合并。

### 4.8 SQLite 真实业务

SQLite 采用 100000 行、每行 512 B payload、只读 indexed range aggregate
（span=1024），4 个进程固定核心；解压任务仍固定约 4096 MiB/s，并与 CPU/GPU
worker 在 core 0 公平争用。

| 场景 | QPS mean | 相对 baseline | p99 mean |
|---|---:|---:|---:|
| 无解压 | 20093 | 100.0% | 278.9 μs |
| CPU LZ4 | 19131 | 95.2% | 1158.3 μs |
| GPU LZ4 | **20523** | **102.1%** | **573.0 μs** |

GPU 相对 CPU 路径 QPS 高约 7.3%，p99 低约 50.5%。但 GPU p99 仍约为无解压
baseline 的 2.05 倍，且 baseline 与 GPU 的小幅 QPS差异不能外推为数据库加速；
可支持的结论是 GPU offload 显著减轻了 CPU 解压造成的业务干扰。

### 4.9 O_DIRECT 与设备边界

512 MiB、128 KiB、15 秒的 fio 实验中，测试程序确认 `F_GETFL` 仍含
`O_DIRECT`，header 与 block span 均满足 4 KiB 对齐，逻辑内容校验通过；
fio 错误数为 0，读取为 62.9 MiB/s。

该结果运行在项目盘 `/dev/sda2`（ext4、SATA SSD）。机器虽存在
`nvme0n1`（Fanxiang S500Pro 1TB），但设备未挂载且当前会话无挂载权限，因而
不能把 62.9 MiB/s 写成 NVMe 性能。

### 4.10 主机内存与性能计数器边界

统一 CSV 已包含 CPU time、RSS、page fault、context switch、GPU utilization、
power 和 GPU pipeline 分段。管理员在宿主机加载 MSR 后，
`results/final/pcm_dram_512m_v100_20260730/` 使用 512 MiB 轮转工作集；
allocation、compression 和 warmup 完成后通过 ready/start 握手启动 10 秒稳态，
PCM 每秒采样并只汇总完全位于稳态区间内的 9 个样本。Baseline、CPU LZ4、
GPU LZ4 各五轮，CPU/GPU 都限制在约 4096 MiB/s，4 个业务 worker 与解压任务
使用相同亲和性，并轮换场景顺序：

| 场景 | DRAM Read MB/s | 95% CI | DRAM Write MB/s | 95% CI | DRAM Total MB/s | 95% CI |
|---|---:|---:|---:|---:|---:|---:|
| Baseline | 23.80 | ±4.66 | 20.53 | ±1.53 | 44.33 | ±6.20 |
| CPU LZ4 | 4416.34 | ±22.62 | 4329.12 | ±9.45 | 8745.46 | ±29.06 |
| GPU LZ4 | 86.40 | ±3.51 | 4483.11 | ±9.70 | 4569.51 | ±7.15 |

CPU/GPU 实际解压吞吐分别为 4093.00±2.24 和 4093.96±2.27 MiB/s。相同逻辑
吞吐下，GPU 总 DRAM bandwidth 比 CPU 低约 **47.75%**：CPU 路径同时从主机
内存读取约 4.42 GB/s 并写入约 4.33 GB/s；GPU 路径读取的是压缩输入，主机读取
约 86 MB/s，但 D2H 仍写入约 4.48 GB/s。GPU 写带宽反而比 CPU 高约 3.56%，
所以准确结论是“减少总主机 DRAM 带宽，未消除写回流量”。

GPU 最大 RSS 为 1168728.8 KiB，CPU 为 1072827.2 KiB，GPU 高约 8.94%，因此
没有 DRAM 容量节省证据。第一版 16 MiB 结果保留在
`results/final/pcm_dram_v100_20260730/` 作为 cache-resident 方法学反例，不再
作为主结论。PCM 是全系统 IMC 口径，不能当成单进程精确流量。

`results/final/perf_offload_v100_20260730/` 另用 `perf_event_open` 在初始化、
压缩和 warmup 之后启用进程及继承线程计数器，只覆盖 10 秒稳态阶段。512 MiB
轮转工作集、固定约 4096 MiB/s、五轮结果为：

| 场景 | 业务 ops/s | Instructions | Cache references | Cache misses | Miss rate |
|---|---:|---:|---:|---:|---:|
| Baseline | 1.7994e9 | 2.1597e11 | 5.74e3 | 743 | 12.99% |
| CPU LZ4 | 1.5738e9 | 2.1262e11 | 6.7635e8 | 6.4359e8 | 95.16% |
| GPU LZ4 | **1.6376e9** | **2.0745e11** | 7.0867e8 | **8.60e5** | **0.12%** |

GPU 相对 CPU 多保留约 4.06% 业务吞吐，用户态 instructions 少约 2.43%，通用
cache misses 少约 99.87%。本机型号化 `LLC-loads/LLC-load-misses` 事件不受
支持，因此表中是 Linux 通用硬件 cache 事件，不能改名为精确 LLC-load-misses。

### 4.11 压缩成本与 break-even

`results/final/break_even.csv` 对 cold-cache、Linux headers 和 25–100%
可压缩率梯度逐项比较实测读取吞吐。所有 COMPRESSED 路径都慢于对应 Baseline；
因此即便把离线压缩耗时假设为 0，也没有正的读取次数性能 break-even。加入实测
0.66–1.65 s/128 MiB 的压缩耗时只会扩大差距。

当前 break-even 只存在于“空间容量是否值得”的业务决策，不存在于已测场景的
总读取时间。文件大小 × 可压缩率 × 并发数的正向时间交叉图应等读路径优化后再画。

### 4.12 随机 I/O、写入与尾延迟矩阵

新增五轮 fio 矩阵覆盖 4/16/128 KiB、顺序读、随机读、顺序写、随机写和
70:30 随机混合读写，并保存平均值、95% CI、p95/p99/p99.9。Baseline 另测
libaio QD 1/8/32；GPUC 走同步 libc Hook，因此不把应用 AIO 冒充为已拦截能力。
COMPRESSED 文件按设计只读，写入矩阵仅比较 Baseline 与 Hook RAW。

该矩阵还发现并修复了 fio 预分配兼容性：缺失的 `ftruncate64`、
`fallocate(64)`、`posix_fallocate(64)` 拦截，以及内部物理长度查询再次经过
Hook，会导致 RAW 文件逻辑长度在随机写后反复少 56 字节并最终 EIO。新增回归
测试执行 512 次随机 `pwrite` 后读取逻辑文件尾。完整数据见
`results/final/io_workload_matrix_v100_20260729/`。

### 4.13 公开真实数据集

使用 Project Gutenberg ebook #2600《War and Peace》的官方 UTF-8 文本：
3,359,610 字节，SHA-256
`2d5bb2ad5f422765e714617e21fa31bbaf8958aa79682c86fca6660fcc5d1b2b`。
结果目录同时保存下载 URL、目录页、许可证页与目录更新时间。

五轮中 SGLZ 均未达到 85% 压缩门限并正确保留 RAW，占用比 100.10%；
nvCOMP LZ4 进入 COMPRESSED，占用比 **68.76%**。LZ4 压缩耗时
0.975 ± 0.017 s，cold/warm 逻辑读取分别为 17.52 ± 0.25 和
112.07 ± 3.08 MiB/s，仍显著慢于普通文件。这说明真实文本上 LZ4 有空间收益，
但当前读路径没有性能收益。

### 4.14 pidstat、sar 与能效边界

CPU/GPU/无解压三场景均五轮保存 `pidstat -u -r -w`、`sar -u -r -B -W`
和 200 ms `nvidia-smi` 原始日志。固定约 4 GiB/s 时，GPU worker 平均约
0.509 s/5 s 主机 CPU，GPU 利用率约 45.7%。Intel PCM IMC 与进程级通用
cycles/instructions/cache 事件已在 4.10 节单列；精确型号化 LLC 事件仍不支持。

V100 板卡边界下，GPU 场景平均功耗约 59.97 W，空闲场景约 58.05 W；
按二者差值计算的增量能耗约 **0.482 J/GiB**。这不是 CPU package 或整机
J/GiB：本机没有 RAPL、IPMI 或外部功率计，不能把板卡边界扩大解释。

### 4.15 文件系统压缩基线与 vdbench 前置条件

仓库已增加 Btrfs/ZFS/DM 能力审计，并将 `tests/btrfs_compare.sh` 重写为安全的
一次性 loop 实验：只允许格式化脚本自行创建且经 backing-file 反查确认的
`/dev/loopN`，通过 `compress-force=zstd:3` 和显式 defrag 保证尝试压缩，比较
ext4 plain、ext4+GPUC LZ4、Btrfs zstd 的相同 SHA、空间、顺序/随机 fio、CPU
和尾延迟。

`results/final/btrfs_zstd_v100_20260731/` 使用每页带不同请求编号、但主体高度
重复的合成日志型数据，已完成六组各五轮，30/30 个 fio 样本 `error=0` 且逻辑
SHA-256 一致。`compsize -b` 确认全部 extent 使用 zstd，
物理占用 8,388,608 B / 268,435,456 B，即 3.125%；`filefrag` 同时记录
`encoded` 标志。GPUC LZ4 占用 16,867,328 B，即 6.284%。

| 路径 | 128 KiB 顺序 MiB/s | 95% CI | 4 KiB 随机 MiB/s | 95% CI | 数据占用比 |
|---|---:|---:|---:|---:|---:|
| ext4 plain | 8256.55 | ±87.88 | 3652.34 | ±47.28 | 100.006% |
| ext4 + GPUC LZ4 | 383.73 | ±6.95 | 2.114 | ±0.054 | 6.284% |
| Btrfs zstd:3 | 8761.48 | ±150.49 | 3786.70 | ±24.85 | 3.125% |

这组 fio 使用 `invalidate=0`，准备阶段也已把页面带入缓存，所以是
**buffered warm-cache 应用可见路径**，不是 loop 后端或 NVMe 介质吞吐。
普通 ext4 与 Btrfs 的计时读主要命中内核未压缩 page cache；GPUC 没有同等大小的
完整逻辑页缓存，Hook cache miss 仍需索引、CUDA 调度、至少一个 128 KiB block
解压、D2H 和应用拷贝。4 KiB 请求相对 128 KiB 压缩单元还有至少 32 倍粒度放大，
因此 Btrfs/GPUC 随机读相差约 1791 倍。Btrfs 相对 plain 的顺序 +6.12%、
随机 +3.68% 只能视为本机暖缓存波动/路径差异，不能归因于 zstd，也不能外推到
NVMe。3.125%/6.284% 的空间比也只适用于该高度可压缩输入。当前可靠结论是
Btrfs 压缩真实生效、该数据上的空间效率优于 GPUC LZ4，
以及 GPUC 用户态逐请求路径仍有显著开销。ZFS/zpool 和 DM target 尚未实现。

用户提供已接受 Oracle 许可的 Vdbench 5.04.07 后，项目使用私有 Temurin Java 8
完成自检和正式实验。许可包与 Java 均位于被忽略的 `third_party/manual/`，
不随仓库再分发；可复现脚本和实验结果进入仓库。

### 4.16 userfaultfd mmap、故障恢复与覆盖率

`results/final/mmap_userfaultfd_v100_20260729/` 在 64/256 MiB、单线程、每组五轮
验证逐页非零 pattern，所有 mismatch 均为 0。256 MiB COMPRESSED 结果：

| 指标 | 均值 | 95% CI |
|---|---:|---:|
| `mmap()` 返回 | 0.215 ms | ±0.011 ms |
| 首次 fault | 146.502 ms | ±3.836 ms |
| 完整扫描 | 5651.449 ms | ±367.254 ms |

旧同步方案的 256 MiB `mmap()` 返回约 1.21 s；新方案降至约 0.22 ms，但首次
fault 包含 CUDA lazy-init，完整扫描仍约 5.65 s。8 线程结果见
`mmap_userfaultfd_threads8_v100_20260729/`：256 MiB 完整扫描
5376.3 ± 159.1 ms，没有稳定的线性扩展。结论是返回延迟问题已解决，解压成本被
推迟到访问阶段，吞吐仍需继续优化。

`results/final/fault_recovery_v100_20260729/` 的五项确定性注入全部 PASS：
Daemon ENOSPC 保留原 RAW 与 SHA 并清理临时文件；压缩中 SIGKILL 不改变原 inode；
重启可覆盖残留临时文件并生成有效 COMPRESSED；GPU 不可见时 CPU fallback SHA
一致；`/dev/full` 错误可向上传播。真实 GPU reset 和主机掉电需要管理员级隔离
环境，本机未执行。

`results/final/stability_10m_v100_20260729/` 对 256 MiB COMPRESSED 以 128 KiB
单线程连续读取 600 秒：fio `error=0`，实际 runtime 600002 ms，带宽
63.918 MiB/s，600 个一秒样本的变异系数 9.05%，p99 8454.1 µs；运行前后逻辑
SHA-256 完全一致。脚本默认可运行 1 小时，但本报告只陈述实际完成的 10 分钟，
不把配置能力冒充已执行时长。

`results/final/coverage_cpu_20260729/` 使用 GCC gcov：

| 源文件 | 行覆盖率 | 分支执行率 |
|---|---:|---:|
| `src/hook.c` | 41.38% | 50.06% |
| `src/cpu_daemon.c` | 62.15% | 77.27% |
| `src/cpu_compress.c` | 85.52% | 88.00% |
| `src/cpu_lz4.c` | 70.83% | 94.74% |

CI 将 Hook 行覆盖率 35% 设为最低门槛。GPU kernel 仍以功能、CRC/SHA 和集成测试
覆盖，不能把 CPU gcov 数字外推为 CUDA 行覆盖率。

### 4.17 fio 压缩多线程退出稳定性

fio `--thread=1 --numjobs=4` 读取 COMPRESSED 文件时曾在作业结束后长时间不返回。
系统调用与线程等待分析表明，多个 fio 线程同时 `close()` 时等待 Hook 的 fd 表
全局锁；持锁线程正在通过 `cudaFreeHost()` 释放 read-ahead 页锁定缓冲区。
CUDA 释放可能与驱动同步，不应处于进程级元数据锁的临界区。

修复将 fd 引用摘除与资源销毁拆开：锁内仅更新 fd 表和引用计数，锁外才释放
blocks、read-ahead 和 cache 缓冲区。`io_workload_matrix.sh` 同时恢复
COMPRESSED 的 1/4 线程组合，并为每个样本增加 TERM/KILL 超时边界。

`results/final/fio_compressed_threads_v100_20260730/` 使用 64 MiB 逐页不同的
可压缩非零 pattern，覆盖 SGLZ/LZ4、4/16/128 KiB、1/4 线程，每组五轮：

| 算法 | 块大小 | 1 线程 MiB/s | 4 线程 MiB/s | 最大墙钟时间 | 错误/超时 |
|---|---:|---:|---:|---:|---:|
| SGLZ | 4 KiB | 39.87 ± 1.94 | 90.23 ± 2.09 | 3.782 s | 0/0 |
| SGLZ | 16 KiB | 44.76 ± 1.69 | 110.72 ± 4.41 | 3.783 s | 0/0 |
| SGLZ | 128 KiB | 71.73 ± 3.95 | 173.19 ± 10.07 | 3.785 s | 0/0 |
| LZ4 | 4 KiB | 372.79 ± 5.27 | 1445.09 ± 9.30 | 3.771 s | 0/0 |
| LZ4 | 16 KiB | 366.60 ± 7.81 | 1454.31 ± 11.04 | 3.769 s | 0/0 |
| LZ4 | 128 KiB | 380.40 ± 1.87 | 1462.86 ± 7.99 | 3.779 s | 0/0 |

全部 60 个样本 fio error=0、逻辑 SHA-256 一致；3 秒 fio runtime 的最大进程
墙钟时间为 3.785 秒，未触发 35 秒超时。该结果证明已消除本次线程退出卡死，
不应外推为任意线程数或任意应用的无界稳定性证明。

### 4.18 Vdbench 正式实验与共享 fd 修复

`results/final/vdbench_v100_20260730/` 使用 Vdbench 5.04.07、256 MiB 逐页
确定性非零 pattern、4 个线程、2 秒 warmup、10 秒计时，每组重复五次。所有路径
统一为 buffered warm-cache，避免 Baseline 使用 `O_DIRECT`、RAW 因紧凑 header
自动清除 `O_DIRECT` 所造成的不公平比较。顺序读块大小为 128 KiB，随机读为
4 KiB；70:30 随机混合读写只比较可写的 Baseline 和 Hook RAW，COMPRESSED
只读对象不参与写入。

| 路径 | workload | 吞吐均值 MiB/s | 95% CI | 平均响应 ms | p99 直方图桶上界均值 ms |
|---|---|---:|---:|---:|---:|
| Baseline | 顺序读 | 26358.40 | ±100.18 | 0.0185 | 0.04 |
| Hook RAW | 顺序读 | 27027.51 | ±179.05 | 0.0181 | 0.04 |
| SGLZ | 顺序读 | 51.79 | ±1.76 | 8.8766 | 18.8 |
| LZ4 | 顺序读 | 44.48 | ±2.22 | 11.1868 | 400.0 |
| Baseline | 4 KiB 随机读 | 2123.26 | ±40.01 | 0.0029 | 0.02 |
| Hook RAW | 4 KiB 随机读 | 2142.58 | ±83.90 | 0.0032 | 0.02 |
| SGLZ | 4 KiB 随机读 | 1.68 | ±0.12 | 9.3532 | 104.8 |
| LZ4 | 4 KiB 随机读 | 0.40 | ±0.01 | 17.9900 | 36.0 |
| Baseline | 70:30 混合 | 1976.09 | ±68.78 | 0.0038 | 0.02 |
| Hook RAW | 70:30 混合 | 2009.95 | ±49.25 | 0.0037 | 0.02 |

50/50 个样本状态正确，逻辑 SHA-256 完全一致，Hook 场景的 Vdbench CPU 字段均为
数值。p95/p99 来自 Vdbench 直方图桶上界，不是精确分位数。Baseline/RAW 数字
主要反映页缓存和内存复制，不能称为 SATA 或 NVMe 介质吞吐。

Vdbench 的多个工作线程共享同一个文件描述符，首次运行因此暴露了 LZ4
read-ahead/cache 状态竞争并产生 `EIO`。修复后，同一 open file description
的受管读取由独立 mutex 保护；不同 `open()` 产生的 fd 仍可并行。新增
`tests/test_shared_pread.sh`，以 4 线程共享一个 fd 做随机 `pread` 并逐字节验证
SGLZ/LZ4，已纳入 `make test`。同时，Hook 对 `st_size=0` 的空只读对象直接透传，
避免把 `/proc/stat` 等伪文件注册为 RAW。该修复保证共享 fd 正确性，但会序列化
同一 fd 的压缩读取；本次极低的随机读吞吐正是当前架构限制，不能包装成正向性能。

### 4.19 LZ4 小请求读取放大修复与严格 A/B

审计发现旧 LZ4 Hook 在 read-ahead miss 时固定读取并解压 32 个 128 KiB block。
因此一次 4 KiB 随机请求会触发最多 4 MiB 的文件读取、GPU 解压和 D2H 返回，
请求放大约 1024 倍；每线程 TLS batch buffer 也会立即按 32 blocks 分配。

修复后，随机访问只处理请求覆盖的 block，连续访问窗口按
`1 → 8 → 16 → 32` 增长；TLS compressed/decompressed buffer 随窗口按 2 的幂
扩容。`GPUC_LZ4_ADAPTIVE_READAHEAD=0` 保留旧行为作为单变量对照。

`results/final/lz4_adaptive_readahead_v100_20260730/` 对同一个 256 MiB
不可变 LZ4 文件运行 buffered warm-cache fio。两种策略、三种 workload、
1/4 threads 各五轮，共 60/60 样本 fio error=0 且逻辑 SHA-256 一致：

| 负载 | Threads | 固定 32-block MiB/s | 请求感知 MiB/s | 吞吐变化 | p99 变化 | RSS 变化 |
|---|---:|---:|---:|---:|---:|---:|
| 4 KiB 随机读 | 1 | 0.380 | 2.246 | +490.2% | -91.0% | -2.2% |
| 4 KiB 随机读 | 4 | 1.479 | 7.670 | +418.7% | -89.5% | -8.5% |
| 128 KiB 随机读 | 1 | 12.036 | 70.242 | +483.6% | -92.1% | -2.1% |
| 128 KiB 随机读 | 4 | 47.561 | 254.341 | +434.8% | -89.2% | -7.0% |
| 128 KiB 顺序读 | 1 | 381.400 | 379.732 | -0.4% | 0.0% | +0.9% |
| 128 KiB 顺序读 | 4 | 1482.186 | 1450.575 | -2.1% | 0.0% | +0.7% |

顺序读差异的 95% CI 重叠，不能解释为稳定退化。顺序访问最终增长到 32-block，
因此不会获得随机负载的 RSS 降幅。

`results/final/vdbench_lz4_adaptive_v100_20260730/` 进一步以 Vdbench 5.04.07、
4 threads、2 秒 warmup、10 秒计时各运行五轮。随机读由旧正式值
0.40 MB/s 提高到 **2.156 ±0.038 MB/s**，顺序读由 44.48 MB/s 提高到
**65.278 ±3.795 MB/s**，10/10 样本状态和 SHA-256 正确。该工程前后比较还包含
TLS 按需缓冲优化，不应替代上面的严格单变量 fio A/B。

这项修复消除了明确的内部读取放大并显著改善尾延迟，但绝对吞吐仍远低于普通文件
Baseline；结论仍是“GPU offload 减少主机 CPU/DRAM 竞争并提供压缩空间收益”，
而不是“压缩文件读取已快于普通文件”。

### 4.20 CPU/GPU LZ4 压缩侧公平实验

审计发现 `gpu_lz4_compress_batch()` 名义上接收 32 个 block，旧实现却循环调用
单块 API，并在每个 128 KiB block 后同步一次。当前实现增加独立的长期
compression pool，把整批输入、指针和长度一次传入
`nvcompBatchedLZ4CompressAsync`，只同步一次；环境变量
`GPUC_LZ4_SERIAL_COMPRESS=1` 保留旧路径作为严格消融。Daemon 现在也会检查
batch 返回数量，失败时终止原子转换，不再继续使用未定义输出。

`results/final/lz4_compress_fair_v100_20260730/` 使用同一确定性 512 MiB
工作集、128 KiB block、batch=32，各五轮。CPU 与 GPU batch 都限制为
1024 MiB/s；旧 GPU serial 因达不到目标，按最大吞吐运行：

| 路径 | 吞吐 MiB/s | 95% CI | 主机 CPU cores | 95% CI | 最大 RSS KiB |
|---|---:|---:|---:|---:|---:|
| CPU liblz4 | 1023.983 | ±0.001 | **0.276** | ±0.003 | 537233 |
| GPU nvCOMP batch | 1023.984 | ±0.002 | 0.365 | ±0.002 | 645769 |
| GPU 旧 serial | 55.821 | ±0.313 | 0.539 | ±0.005 | 631237 |

真 batch 相对旧 serial 至少提高 **18.34 倍**，且三者压缩率均为 0.4936%，
正确性预热逐块用 CPU LZ4 解压比对。但是同为 1024 MiB/s 时，GPU batch 的主机
CPU 比 CPU liblz4 高约 32.0%，RSS 也更高。因此压缩侧当前只证明批量化大幅修复
旧实现，**不支持“GPU 压缩降低主机 CPU”**；项目的主机 CPU 卸载结论只适用于
4.7 节已经验证的解压侧。

V100 板卡功耗由 `nvidia-smi` 采样，包含空闲板卡功耗。压缩侧 PCM 已使用同一
512 MiB 工作集、128 KiB block、batch=32、约 1024 MiB/s 吞吐完成五轮，每轮
汇总 9 个完整稳态一秒区间：

| 路径 | DRAM Read MB/s | 95% CI | DRAM Write MB/s | 95% CI | DRAM Total MB/s | 95% CI |
|---|---:|---:|---:|---:|---:|---:|
| CPU | 1288.02 | ±4.85 | 108.83 | ±0.86 | 1396.85 | ±5.60 |
| GPU | 1302.01 | ±31.77 | 507.38 | ±46.92 | 1809.39 | ±69.25 |

GPU 总 DRAM bandwidth 高约 **29.53%**，主要因为写带宽高约 366.22%；读带宽
只差约 1.09% 且 95% CI 重叠。相同吞吐下 GPU/CPU 主机成本为
0.358/0.282 core，GPU 高约 26.95%，最大 RSS 高约 20.17%。因此压缩侧没有
主机 CPU、DRAM bandwidth 或 RSS 优势；解压侧收益不能外推。PCM 是全系统 IMC
口径。CPU package 与整机能效仍因没有 RAPL、IPMI 或外部功率计而无法测量。

### 4.21 部署、真实扫描和外部参考状态

`results/final/clean_deploy_gpu_v100_20260731/` 在新的临时路径中排除原
`.git`、`bin`、历史结果、PPT、node_modules 和手工许可包，使用随仓依赖重新生成
构建产物。check-env、CPU smoke、docs check、GPU 全量 build 和 GPU
unit/integration 全部 PASS，总耗时约 46 秒。该结果证明随仓依赖与路径独立性，
但不等价于在全新操作系统上从网络重新安装 CUDA/nvCOMP。

`results/final/real_scan_v100_20260731/` 将本机真实 dpkg status 和 Bash ELF
字节组成 64 MiB 可追溯 corpus，通过 Hook 生成 LZ4 压缩对象。普通文件、CPU
LZ4、GPU LZ4 各五轮的业务 hash、4188 个 marker 和逻辑长度完全一致：

| 路径 | 吞吐 MiB/s | 95% CI | 完整扫描 p99 ms | 95% CI | CPU cores |
|---|---:|---:|---:|---:|---:|
| 普通文件 | 718.520 | ±4.059 | 210.495 | ±1.553 | 1.000 |
| CPU LZ4 Hook | 156.487 | ±4.476 | 662.763 | ±46.295 | 0.719 |
| GPU LZ4 Hook | 157.252 | ±7.322 | 606.939 | ±40.831 | 0.720 |

压缩对象占 36,585,472 B，为逻辑大小的约 54.52%。CPU/GPU 吞吐和 p99 的
95% CI 均重叠，不能声称 GPU 在该扫描中更快；有效结论是半结构化与二进制真实
内容可以通过两种压缩后端得到完全一致的应用输出，并再次确认压缩读取仍慢于普通
文件。

公开参考整理在 `docs/EXTERNAL_BASELINES.md`，内核迁移方案在
`docs/KERNEL_INTEGRATION_DESIGN.md`。它们用于约束 nvCOMP batch、Btrfs
128 KiB extent、DM metadata transaction 和 OpenZFS record 语义，不把不同硬件
或数据集的官方示例数字当作本项目性能。

### 4.22 吞吐与压缩率敏感性

`results/final/offload_sensitivity_v100_20260731/` 将原来的单一
4096 MiB/s、高可压缩输入扩展为 1024/2048/4096 MiB/s × 0%/50%/100%
可压缩页。128 MiB 工作集的实际 LZ4 存储比分别为
100.0008%/50.3259%/0.4936%，四个业务线程与解压线程同核竞争，各组五轮。

| 目标 MiB/s | 可压缩页 | CPU 业务保留 | GPU 业务保留 | GPU-CPU | CPU 解压 host core | GPU 解压 host core |
|---:|---:|---:|---:|---:|---:|---:|
| 1024 | 0% | 93.34% | 93.47% | +0.13 pp | 0.246 | 0.117 |
| 1024 | 50% | 95.49% | 95.97% | +0.48 pp | 0.176 | 0.164 |
| 1024 | 100% | 96.32% | 97.09% | +0.77 pp | 0.148 | 0.117 |
| 2048 | 0% | 87.16% | 87.27% | +0.10 pp | 0.459 | 0.205 |
| 2048 | 50% | 91.46% | 92.75% | +1.29 pp | 0.335 | 0.286 |
| 2048 | 100% | 93.00% | 95.34% | +2.34 pp | 0.280 | 0.192 |
| 4096 | 100% | 87.77% | 91.27% | +3.50 pp | 0.487 | 0.353 |

表中仅包含 CPU/GPU 均达到至少 99% 目标的公平组。逐轮配对差在
1024 MiB/s、0% 输入为 +0.132±0.630 pp，2048 MiB/s、0% 输入为
+0.104±0.148 pp，均不能证明业务收益；收益随吞吐与压缩率提高而增强。
4096 MiB/s 下，0% 输入 CPU/GPU 仅达到 2909.50/2983.18 MiB/s，50% 输入
达到 3829.90/3108.85 MiB/s，必须作为饱和点，不能伪装成固定吞吐比较。

`results/final/lz4_compress_sensitivity_v100_20260731/` 进一步测量不限速压缩
峰值：0%/50%/100% 可压缩页下，CPU 为 4850.92/6283.75/7842.97 MiB/s，GPU
batch 为 423.45/459.51/1300.61 MiB/s，即 CPU 的 8.7%/7.3%/16.6%。GPU 进程
host core 较低，但同时完成的工作量远少，不能据此声称固定吞吐 CPU 卸载；结合
4.20 节同吞吐和 PCM 结果，压缩侧负结论保持不变。

敏感性矩阵把解压侧结论收窄为：GPU 能减少解压 host CPU，但并行业务是否获得
可见收益取决于吞吐、压缩率和系统是否接近 CPU 竞争瓶颈。PCM 代表组已在4.24节
补齐；真实 corpus 上的同类资源矩阵仍待补充。

### 4.23 SQLite 直接读取压缩对象

审计发现旧 `sqlite_direct_read_v100_20260731/` 和 fixed32 目录虽然设置
`GPUC_ALGO=lz4`，却调用只生成 SGLZ 的 `cpu_compress_daemon`；文件头实际为
`comp_algo=1`。原来的 329.86/21.79 QPS 不能标作 LZ4，两个旧目录已明确标为
历史无效。修复后的 runner 改用支持 LZ4 的 daemon，并强制校验算法 ID 为2。

有效结果使用100000行mixed payload、单worker、256行indexed range aggregate，
每轮3秒、各五轮。严格GPU-only设置`GPUC_LZ4_SMALL_READ_CPU_BLOCKS=0`；混合
分流在应用请求只覆盖一个128 KiB block时走CPU liblz4，较大批量仍保留GPU路径。

| 路径 | QPS | 95% CI | p99 us | 95% CI | host cores |
|---|---:|---:|---:|---:|---:|
| 普通文件（hybrid轮转组） | 22197.22 | ±71.97 | 102.34 | ±1.71 | 1.084 |
| CPU LZ4 | 109.34 | ±1.33 | 11865.45 | ±861.96 | 1.037 |
| LZ4混合分流 | 108.33 | ±0.30 | 11619.09 | ±127.25 | 1.034 |
| LZ4严格GPU-only | 55.67 | ±1.33 | 24473.48 | ±339.86 | 0.696 |

混合分流相对严格GPU-only的QPS提高94.58%，p99降低52.52%，说明小请求不进入
CUDA可显著缓解固定开销；但它与CPU LZ4基本持平，且仍比普通文件慢99%以上。
因此应称为“CPU/GPU混合策略”，不能把提升冒充GPU加速。COMPRESSED只读语义和
用户态128 KiB粒度仍不适合高性能数据库点查。

### 4.24 PCM敏感性与Btrfs真实corpus文件级失效

`results/final/pcm_dram_sensitivity_v100_20260731/` 使用512 MiB轮转工作集，
选择1024 MiB/s+0%、2048 MiB/s+50%、4096 MiB/s+100%三个代表点。实际LZ4
存储比分别为100.0008%、50.3637%、0.4936%，每点Baseline/CPU/GPU各五轮，
CPU/GPU均达到约99.9%目标吞吐。

| 目标与可压缩率 | CPU总DRAM | GPU总DRAM | GPU−CPU配对差 | GPU业务相对CPU | GPU RSS相对CPU |
|---|---:|---:|---:|---:|---:|
| 1024 MiB/s，0% | 3251.96 MB/s | 3248.40 MB/s | −3.56±1.34 MB/s（−0.11%） | −0.04% | +5.80% |
| 2048 MiB/s，50% | 5376.37 MB/s | 5070.58 MB/s | −305.79±15.48 MB/s（−5.69%） | +1.27% | +7.19% |
| 4096 MiB/s，100% | 8686.21 MB/s | 4567.45 MB/s | −4118.76±20.10 MB/s（−47.42%） | +4.19% | +8.92% |

DRAM收益不是固定比例：不可压缩RAW块几乎没有优势，中等压缩率只有约5.7%，
高可压缩高吞吐才达到约47%。三个点GPU RSS都更高，且中高压缩率仍有明显D2H
写入，所以结果只支持“特定条件下降低总IMC bandwidth”，不支持降低主机内存
容量或消除写回。

`results/final/btrfs_real_cold_v100_20260731/` 使用可追溯的dpkg status+Bash ELF
字节形成256 MiB corpus，比较ext4普通文件、ext4+GPUC LZ4和loop Btrfs zstd:3。
fio对每个文件使用`invalidate=1`，顺序128 KiB/随机4 KiB各五轮，30/30
`error=0`且逻辑SHA一致。

| 路径 | 空间占用 | 顺序128 KiB | 随机4 KiB |
|---|---:|---:|---:|
| ext4普通文件 | 100.01% | 354.22±3.58 MiB/s | 21.65±1.93 MiB/s |
| ext4+GPUC LZ4 | 54.61% | 89.41±5.81 MiB/s | 0.541±0.003 MiB/s |
| Btrfs zstd:3 | 36.36% | 1906.51±61.23 MiB/s | 11.37±0.79 MiB/s |

Btrfs真实corpus空间效率优于GPUC，GPUC两种读取仍明显落后。`invalidate=1`只做
文件页缓存失效，未写全系统`drop_caches`、未刷新设备缓存，Btrfs还位于loop
backing file上；因此1906 MiB/s不是磁盘或NVMe吞吐。

### 4.25 H2D合并与小请求分流优化

LZ4解压原先为每个压缩block提交一次H2D DMA。当前先把同一batch的压缩payload
打包到pinned host buffer，再用一次H2D提交；`GPUC_H2D_COALESCE=0`保留旧路径。
512 MiB工作集、128 blocks/batch、每组五轮的严格消融为：

| 模式 | 吞吐 MiB/s | 95% CI | H2D ms/batch | 95% CI |
|---|---:|---:|---:|---:|
| 逐block H2D | 4805.13 | ±137.14 | 0.2713 | ±0.0149 |
| 合并H2D | 5275.91 | ±451.14 | 0.0393 | ±0.0028 |

吞吐提高9.80%，H2D阶段降低85.51%。独立128-block高可压缩微基准的GPU中位数
由关闭合并时的6010.76提高到开启时的7634.04 MiB/s，但CPU仍为11479.76
MiB/s，绝对速度差距由约47.7%收窄到约33.5%，没有反转。

Vdbench 128 MiB真实LZ4、4线程4 KiB随机读也完成相同fixture的五轮A/B：

| 策略 | MB/s | 95% CI | 平均响应 ms | p99桶上界均值 |
|---|---:|---:|---:|---:|
| 严格GPU-only | 2.076 | ±0.136 | 6.947 | 92 ms |
| 单block CPU分流 | 12.239 | ±0.263 | 0.819 | 2 ms |

混合策略吞吐提高5.89倍、平均响应降低88.21%。该数据证明按粒度选择设备是必要的，
但12.2 MB/s仍远低于普通文件，不能改写总体负结论。GPU worker同时支持将已经排队
的多调用合成一次batch；4连接短诊断只观察到约1.6%吞吐差，样本不足且收益不明确，
因此不把跨调用合批列为已证明的性能收益，只保留并发正确性通过的工程能力。

### 4.26 RTX 4090 最终补测

RTX 4090 已补齐此前只在 V100 上存在的应用、mmap、完整 I/O、公开数据集、PCM
和 Btrfs 证据，并保留一小时稳定性与 Vdbench 正式结果。新增目录及原始文件见
`results/final/RTX4090_GAP_ANALYSIS_20260807.md`。

| 项目 | 验收与结果 |
|---|---|
| SQLite 并行业务 | 15/15；GPU 相对 CPU QPS +11.21%、p99 -81.66%、解压进程 CPU 时间 -88.00%，但仍比无解压 baseline 低 5.14% |
| mmap/userfaultfd | 单/8 线程合计 60/60 mismatch=0；256 MiB 完整扫描约 2.31/2.32 s，8 线程未扩展 |
| 自适应预读 | 60/60；4 KiB 随机读相对 legacy 提高 31.71–31.97 倍、p99 降约 96.9%，绝对吞吐仍低于普通文件 |
| 完整 I/O 矩阵 | 465 个 fio JSON、525 行读写指标、105 个 n=5 汇总组，error=0，四路径逻辑 SHA 一致 |
| PG2600 | 压缩 10/10、冷/暖读取 40/40；LZ4 占用 68.76%，暖读 225.44 MiB/s，Baseline 12558.37 MiB/s |
| Btrfs | 合成/真实 corpus 合计 60/60；zstd extent 生效，真实 corpus Btrfs/GPUC 占用 31.46%/48.12% |
| PCM | 128/512 MiB 各 15/15；CPU/GPU 实际只达 3652.6/1392.6 和 3404.1/1314.1 MiB/s，不能作为同 4 GiB/s DRAM 公平 A/B |

PG2600 的 3359610 B 逻辑文件存在非整 128 KiB 尾部。fio 3.28 对 Hook 的最后
一个不完整块报 `full resid`，所以正式暖读统一计时 3276800 B，冷读仍读取并校验
完整文件。该修复同时作用于四条路径，失败首轮未进入最终结果。

4090 PCM 证明脚本能在该双路 Xeon 主机取得完整稳态 IMC 区间，但也暴露 PCM
包裹执行下 GPU 路径饱和更早。由于 CPU/GPU 处理量不同，禁止把两者总带宽的直接
差值写成“同吞吐降低比例”；V100 同吞吐 PCM 仍是 DRAM 正向主证据，4090 两组
作为平台限制与负结果。

## 5. 决赛可陈述的结论

可以陈述：

- 已完成文件语义、损坏格式和 daemon 原子替换的系统性修复；
- 原 16 MiB 高可压缩工作集固定 4 GiB/s 下，GPU 路径较 CPU 路径减少约
  28.8% 的额外主机 CPU 成本；128 MiB 敏感性复测为 27.5%；
- 业务收益随吞吐和压缩率增强：128 MiB 工作集从 1 GiB/s、不可压缩输入的
  +0.13±0.63 pp，增长到 4 GiB/s、高可压缩输入的 +3.50±0.08 pp；
- SQLite 并行场景中 GPU 相对 CPU 路径 QPS 高约 7.3%、p99 低约 50.5%；
- RTX 4090 同类 SQLite 五轮中 GPU 相对 CPU QPS 高 11.21%、p99 低 81.66%；
  一小时持续读、fio 多线程、Vdbench 和完整 I/O 矩阵均通过正确性验收；
- SQLite 数据库直接位于真实LZ4对象时，两种后端都能正确查询；单block CPU分流
  相对严格GPU-only QPS提高94.58%、p99降低52.52%，但仍比普通文件慢99%以上；
- 新版对齐压缩格式已通过真正 `O_DIRECT` 的标志、正确性和 fio 验证；
- SGLZ 在 1→16 线程有约 2 倍扩展，但 32 线程饱和；
- batch/read-ahead 各带来约 11% 单线程提升，最优批大小约 4；
- LZ4 将文本样例空间占用降至约 38%；请求感知预读使 4 KiB 随机读吞吐提高
  4.19–4.90 倍、p99 降约 90%，但绝对性能仍低于 Baseline；
- 公开 Gutenberg 文本上 LZ4 allocated ratio 为 68.76%，SGLZ 正确回退 RAW；
- 随机/写入矩阵已覆盖 4/16/128 KiB、尾延迟和 Baseline QD 1/8/32；
- V100 板卡增量边界约 0.482 J/GiB，但不是整机能效；
- 不可压缩数据能回退 RAW，避免无收益压缩。
- userfaultfd 将 256 MiB COMPRESSED 的 `mmap()` 返回降到约 0.215 ms，任意页
  pattern 正确；首次 fault 与完整扫描成本需单独报告；
- COMPRESSED/INLINE 是明确的只读归档对象；确定性 ENOSPC、SIGKILL、重启和
  GPU 不可见恢复测试已通过；
- V100 10 分钟持续读取 fio error=0，600 个带宽样本，前后 SHA 一致；
- CPU Hook 已设置 35% gcov 行覆盖率门槛，当前为 41.38%。
- fio 压缩读的多线程退出锁问题已修复；两算法、三块大小、1/4 线程五轮共
  60/60 样本无超时、无 fio 错误且 SHA 一致。
- Vdbench 5.04.07 三类 workload、4 线程、五轮共 50/50 样本通过，且修复了
  共享 fd 压缩读状态竞争；其压缩随机读结果也明确显示当前架构的性能短板。
- 自适应 LZ4 Vdbench 复测10/10样本通过；进一步的同fixture小请求分流A/B中，
  4 KiB随机读由严格GPU-only的2.076±0.136提高到12.239±0.263 MB/s，仍不
  宣称超过普通文件。
- LZ4合并H2D使512 MiB稳态吞吐提高9.80%，H2D阶段降低85.51%；128-block
  微基准GPU中位数约7.63 GiB/s，仍低于CPU约11.48 GiB/s。
- 512 MiB稳态PCM代表组显示GPU/CPU总DRAM差随吞吐/可压缩率从−0.11%扩大到
  −47.42%；高压缩率收益不能外推到不可压缩数据，且GPU RSS高5.80%–8.92%；
- 真正 nvCOMP 批量压缩相对旧逐块同步至少提高 18.34 倍；但同为
  1024 MiB/s 时 GPU/CPU 主机成本为 0.365/0.276 core，压缩侧不能主张 CPU
  卸载收益；压缩侧 PCM 进一步显示 GPU 总 DRAM bandwidth 高约 29.53%。
- 不限速压缩峰值梯度中，GPU batch 仅为单核 CPU liblz4 吞吐的
  7.3%–16.6%；较低 GPU host CPU 伴随明显更低的处理量，不构成公平卸载收益。
- Btrfs zstd:3 的 extent 压缩已由 `compsize`/`filefrag` 验证，当前数据占用
  3.125%，GPUC LZ4 为 6.284%；暖页缓存性能不能解释为介质或 NVMe 性能。
- 真实dpkg status+Bash ELF corpus文件级失效口径下，Btrfs/GPUC空间占用为
  36.36%/54.61%；GPUC顺序/随机读仍明显落后，loop结果仍不是介质性能；
- 真实 dpkg status + Bash ELF 扫描中 CPU/GPU 业务输出完全一致、压缩占用
  54.52%；两者吞吐 CI 重叠，均明显慢于普通文件。
- 全新临时路径中的 CPU smoke、GPU build/test 和文档检查全部 PASS。

不能陈述：

- 顺序读普遍快于 Baseline；
- GPU 绝对解压吞吐高于 CPU，或压缩文件读快于 Baseline；
- GPU 减少了主机 DRAM 容量，或消除了主机 DRAM 写回；
- 已测得精确型号化 LLC-load-misses；当前只有通用 cache-misses；
- 已完成 NVMe 性能验证；
- GPU 压缩侧已经降低主机 CPU；当前公平实验得到相反结果；
- GPU 解压在所有吞吐和压缩率下都会提高并行业务吞吐；低压缩率低吞吐组差异
  与零重叠，部分 4 GiB/s 组还未达到目标；
- RTX 4090 PCM 已证明同 4 GiB/s 下总 DRAM 降低；该组 CPU/GPU 都未同时达到
  请求吞吐，只能作为 PCM 包裹执行下的饱和边界；
- SQLite/数据库细粒度点查已被 GPUC 加速；直接读取实验得到相反结果；
- 已完成 ZFS 或 DM 性能验证，或Btrfs loop文件级失效等同于真实NVMe冷缓存；
- mmap 每次只解压一个 4 KiB 页，或完整扫描成本已经消失；
- 对任意应用完全透明，或已达到生产级。

## 6. 下一步

1. PCM代表组已完成；下一步只需在真实corpus复核CPU/DRAM卸载敏感性；
2. 在可挂载的独占 NVMe 上复跑 direct I/O，补队列深度、IOPS 与 p99；
3. 在支持型号化 LLC 事件的环境补精确 LLC-load-misses；通用 perf 计数已完成；
4. 继续减少解压 D2H 写回、RSS，以及压缩侧 host orchestration CPU；
5. 优化 userfaultfd handler 的并发调度与首次 CUDA fault 延迟；
6. 在鲲鹏 920 和赛题指定 RTX 平台复跑核心实验；
7. ZFS/DM 实现和供应商无关后端按当前赛程安排暂缓。
