# GPUC 决赛实验报告

> 更新日期：2026-07-29
> 本报告只采用 `results/final/` 中可复核的结果。此前报告中的 jobs=32
> “99.8%”、混合缓存口径和未重复实验均已撤下；2026-07-29 已完成对齐格式，
> 新的 O_DIRECT 结果与旧的伪 O_DIRECT 结果严格区分。

## 1. 项目与实验问题

GPUC 使用 `LD_PRELOAD` 拦截一组 libc 文件接口，在 RAW 文件关闭后由 daemon
离线压缩，并在读取 COMPRESSED 文件时用 GPU 解压。它适用于动态链接、通过已拦截
接口访问普通文件的程序，不覆盖静态链接、直接 syscall、应用自行提交的 io_uring
或任意内核文件路径。

本轮实验回答六个问题：

1. 文件语义和并发替换是否正确；
2. warm/cold cache 下真实吞吐如何；
3. read-ahead、batch、pinned memory 等优化是否有贡献；
4. 长期 GPU worker 是否能释放 CPU 并提高并行业务吞吐；
5. SQLite 真实业务的 QPS 和尾延迟是否受益；
6. 对齐压缩格式能否保留真正的 `O_DIRECT`。

## 2. 环境与方法

- GPU：Tesla V100-SXM2-32GB，compute capability 7.0；
- 驱动：570.181；内核：Linux 5.15.0；fio：3.16；
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

mmap 当前方案是在 `mmap()` 返回前同步准备完整逻辑映射，保证立即访问任意页正确；
它不是 userfaultfd 按需页解压。

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

GPU 单请求平均分段为 queue 0.019 ms、pack 0.003 ms、H2D 0.560 ms、
kernel 0.143 ms、D2H 1.451 ms、unpack 0.001 ms，总计 2.423 ms。D2H 是当前
最大阶段，说明下一轮应优先减少返回拷贝和同步，而不是继续只优化 kernel。

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
power 和 GPU pipeline 分段。当前系统的 `/usr/bin/perf` 缺少 5.15.0 对应工具，
`perf_event_paranoid=2`，未安装 Intel PCM 且无提权权限，因此没有可靠的 IMC
DRAM bandwidth 或 LLC miss 数据。报告明确保留这一缺口，不用 PCIe copy bytes、
磁盘压缩率或 RSS 冒充 DRAM 带宽。

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
0.509 s/5 s 主机 CPU，GPU 利用率约 45.7%。匹配内核的 perf 和 Intel PCM
仍不可用，故 cycles、LLC miss 和 IMC DRAM bandwidth 继续标为环境阻塞。

V100 板卡边界下，GPU 场景平均功耗约 59.97 W，空闲场景约 58.05 W；
按二者差值计算的增量能耗约 **0.482 J/GiB**。这不是 CPU package 或整机
J/GiB：本机没有 RAPL、IPMI 或外部功率计，不能把板卡边界扩大解释。

### 4.15 文件系统与 vdbench 前置条件

仓库已增加 Btrfs/ZFS/DM 只读能力审计，以及 vdbench 顺序读、4 KiB 随机读、
70:30 混合读写参数和 runner。本机无 root/CAP_SYS_ADMIN、无可见 loop 节点，
且没有 ZFS/zpool；Oracle Vdbench 需要接受许可证，同时本机缺 Java/Vdbench。
因此这两项保存了可复核的阻塞证据，但没有生成或伪造性能数字。

## 5. 决赛可陈述的结论

可以陈述：

- 已完成文件语义、损坏格式和 daemon 原子替换的系统性修复；
- 固定 4 GiB/s 下，GPU 路径较 CPU 路径减少约 28.8% 的额外主机 CPU 成本；
- CPU 争用场景中 GPU 保留 97.17% 业务吞吐，CPU 为 89.85%；
- SQLite 并行场景中 GPU 相对 CPU 路径 QPS 高约 7.3%、p99 低约 50.5%；
- 新版对齐压缩格式已通过真正 `O_DIRECT` 的标志、正确性和 fio 验证；
- SGLZ 在 1→16 线程有约 2 倍扩展，但 32 线程饱和；
- batch/read-ahead 各带来约 11% 单线程提升，最优批大小约 4；
- LZ4 将文本样例空间占用降至约 38%，新版读路径约为旧正式值的 2.21 倍；
- 公开 Gutenberg 文本上 LZ4 allocated ratio 为 68.76%，SGLZ 正确回退 RAW；
- 随机/写入矩阵已覆盖 4/16/128 KiB、尾延迟和 Baseline QD 1/8/32；
- V100 板卡增量边界约 0.482 J/GiB，但不是整机能效；
- 不可压缩数据能回退 RAW，避免无收益压缩。

不能陈述：

- 顺序读普遍快于 Baseline；
- GPU 绝对解压吞吐高于 CPU，或压缩文件读快于 Baseline；
- 已测得 DRAM bandwidth/LLC miss，或 GPU 减少了主机 DRAM 容量；
- 已完成 NVMe 性能验证；
- mmap 是按访问页解压；
- 对任意应用完全透明，或已达到生产级。

## 6. 下一步

1. 在可挂载的独占 NVMe 上复跑 direct I/O，补队列深度、IOPS 与 p99；
2. 安装匹配内核的 perf/Intel PCM，补 DRAM bandwidth、LLC miss；
3. 减少 GPU D2H 返回拷贝和上下文切换，继续优化文件读路径；
4. 实现 userfaultfd mmap 按需页解压；
5. 在公开数据库备份等二进制数据上继续扩展已完成的 Gutenberg workload；
6. 在独立 btrfs 压缩卷验证 zstd 生效，并安装许可版 vdbench 后再恢复横向对比。
