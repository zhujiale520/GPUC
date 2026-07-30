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

### 4.15 文件系统与 vdbench 前置条件

仓库已增加 Btrfs/ZFS/DM 只读能力审计。本机无 root/CAP_SYS_ADMIN、无可见
loop 节点，且没有 ZFS/zpool，因此文件系统横向基线仍只报告能力审计，
不伪造性能结果。

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

## 5. 决赛可陈述的结论

可以陈述：

- 已完成文件语义、损坏格式和 daemon 原子替换的系统性修复；
- 固定 4 GiB/s 下，GPU 路径较 CPU 路径减少约 28.8% 的额外主机 CPU 成本；
- CPU 争用场景中 GPU 保留 97.17% 业务吞吐，CPU 为 89.85%；
- SQLite 并行场景中 GPU 相对 CPU 路径 QPS 高约 7.3%、p99 低约 50.5%；
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
- 自适应 LZ4 Vdbench 复测 10/10 样本通过，随机/顺序读达到
  2.156 ±0.038/65.278 ±3.795 MB/s；仍不宣称超过普通文件。
- 512 MiB 稳态 Intel PCM 五轮显示同为约 4094 MiB/s 解压时，GPU/CPU 总
  DRAM 带宽约为 4569.51/8745.46 MB/s，GPU 低约 47.75%；但 GPU D2H 写带宽
  仍约 4483.11 MB/s，且最大 RSS 高约 8.94%。

不能陈述：

- 顺序读普遍快于 Baseline；
- GPU 绝对解压吞吐高于 CPU，或压缩文件读快于 Baseline；
- GPU 减少了主机 DRAM 容量，或消除了主机 DRAM 写回；
- 已测得精确型号化 LLC-load-misses；当前只有通用 cache-misses；
- 已完成 NVMe 性能验证；
- mmap 每次只解压一个 4 KiB 页，或完整扫描成本已经消失；
- 对任意应用完全透明，或已达到生产级。

## 6. 下一步

1. 在可挂载的独占 NVMe 上复跑 direct I/O，补队列深度、IOPS 与 p99；
2. 在支持型号化 LLC 事件的环境补精确 LLC-load-misses；通用 perf 计数已完成；
3. D2H 连续区间合并和 512 MiB 稳态 PCM 已完成；继续减少 D2H 写回及 RSS；
4. 优化 userfaultfd handler 的并发调度与首次 CUDA fault 延迟；
5. 在公开数据库备份等二进制数据上继续扩展已完成的 Gutenberg workload；
6. 在独立 btrfs 压缩卷验证 zstd 生效，并继续补 ZFS/DM 横向对比；
7. 供应商无关后端接口按当前赛程安排暂缓。
