# GPUC 决赛实验报告

> 更新日期：2026-07-29
> 本报告只采用 `results/final/` 中可复核的结果。此前报告中的 jobs=32
> “99.8%”、混合缓存口径、伪 O_DIRECT 和未重复实验均已撤下。

## 1. 项目与实验问题

GPUC 使用 `LD_PRELOAD` 拦截一组 libc 文件接口，在 RAW 文件关闭后由 daemon
离线压缩，并在读取 COMPRESSED 文件时用 GPU 解压。它适用于动态链接、通过已拦截
接口访问普通文件的程序，不覆盖静态链接、直接 syscall、应用自行提交的 io_uring
或任意内核文件路径。

本轮实验回答四个问题：

1. 文件语义和并发替换是否正确；
2. warm/cold cache 下真实吞吐如何；
3. read-ahead、batch、pinned memory 等优化是否有贡献；
4. GPU 解压是否真正释放 CPU 并提高并行业务吞吐。

## 2. 环境与方法

- GPU：Tesla V100-SXM2-32GB，compute capability 7.0；
- 驱动：570.181；内核：Linux 5.15.0；fio：3.16；
- 核心 fio 实验使用 128 KiB 顺序读、`direct=0`；
- 每个正式场景通常重复 5 次，报告 mean、sample stddev 和 95% CI；
- Baseline、Hook RAW、SGLZ/LZ4 使用独立文件且逻辑内容相同；
- 每轮保存 header state、算法、SHA-256、格式长度和 allocated bytes；
- warm-cache 在计时前完整逻辑预读；cold-cache 在底层 inode 上执行
  `POSIX_FADV_DONTNEED` 后只读一遍。

GPUC 紧凑格式的 56 字节头和压缩块 offset 不满足真正 O_DIRECT 的对齐要求。
Hook 对已识别的 GPUC 文件显式清除 `O_DIRECT`，因此不报告 O_DIRECT 性能。

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
| Baseline | 37,703,680 | 100.0% | 9666.0 ± 22.2 |
| Hook RAW | 37,707,776 | 100.0% | 10519.2 ± 207.7 |
| SGLZ | 30,851,072 | 81.8% | 107.8 ± 0.3 |
| nvCOMP LZ4 | 14,356,480 | 38.1% | 81.0 ± 0.1 |

LZ4 读路径由逐块同步改为 4 块 batch 后，从修复前诊断值 29.4 提升到
81.0 MiB/s，但仍慢于 SGLZ。LZ4 的优势目前是空间，不是读取速度。

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

### 4.7 CPU 业务与 GPU 卸载

| 业务线程 | CPU LZ4 保留业务吞吐 | GPU LZ4 保留业务吞吐 | CPU/GPU 解压 MiB/s |
|---:|---:|---:|---:|
| 4 | 87.5% | 87.1% | 8950 / 2074 |
| 1 | 50.1% | 48.6% | 10374 / 2093 |

当前同步 GPU API 没有提高业务吞吐，GPU 提交线程仍占用共享核心。因而“GPU
卸载释放 CPU”不是已证明贡献。后续需要独立服务进程、持久化 nvCOMP device
内存池和真正异步完成通知，再重新验证。

4 workers 场景中，GPU 板卡平均功耗约 45.2 W，解压约 2074 MiB/s，对应约
22.3 J/GiB 的板卡总能耗；相对 idle 44.1 W 的增量约 0.55 J/GiB。该值不包含
CPU/整机功耗，不能与 CPU LZ4 做完整能效结论。

### 4.8 压缩成本与 break-even

`results/final/break_even.csv` 对 cold-cache、Linux headers 和 25–100%
可压缩率梯度逐项比较实测读取吞吐。所有 COMPRESSED 路径都慢于对应 Baseline；
因此即便把离线压缩耗时假设为 0，也没有正的读取次数性能 break-even。加入实测
0.66–1.65 s/128 MiB 的压缩耗时只会扩大差距。

当前 break-even 只存在于“空间容量是否值得”的业务决策，不存在于已测场景的
总读取时间。文件大小 × 可压缩率 × 并发数的正向时间交叉图应等读路径优化后再画。

## 5. 决赛可陈述的结论

可以陈述：

- 已完成文件语义、损坏格式和 daemon 原子替换的系统性修复；
- SGLZ 在 1→16 线程有约 2 倍扩展，但 32 线程饱和；
- batch/read-ahead 各带来约 11% 单线程提升，最优批大小约 4；
- LZ4 将文本样例空间占用降至约 38%，但当前读吞吐低于 SGLZ；
- 不可压缩数据能回退 RAW，避免无收益压缩。

不能陈述：

- 顺序读普遍快于 Baseline；
- 当前版本已经释放 CPU 并提高业务吞吐；
- 支持真正 O_DIRECT；
- mmap 是按访问页解压；
- 对任意应用完全透明，或已达到生产级。

## 6. 下一步

1. 为 nvCOMP LZ4 建持久化 device/host buffer pool，去掉每批
   `cudaMalloc/cudaFree`；
2. 将 GPU 解压迁到独立服务进程或长生命周期 worker，应用线程异步等待完成；
3. 实现 userfaultfd mmap 按需页解压；
4. 在有来源、版本和 SHA-256 的公开日志/模型数据集上补真实 workload；
5. 若要支持 O_DIRECT，重新设计对齐 header、block offset 和 padded length；
6. 在独立 btrfs 压缩卷验证 zstd 生效后，才恢复文件系统压缩对比。
