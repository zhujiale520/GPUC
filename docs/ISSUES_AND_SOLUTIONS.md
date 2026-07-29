# GPUC 关键问题与解决方法

本文只记录已由源码和 2026-07-29 回归验证的问题。性能数值以
[`EXPERIMENTAL_REPORT.md`](EXPERIMENTAL_REPORT.md) 和 `results/final/` 为准。

## 1. 旧并发成绩失真

问题：

- Baseline 与 GPUC 复用文件或内容不一致；
- fio `direct=1` 与 GPUC 的未对齐 header/compact offset 不兼容；
- Hook 探测 O_DIRECT 文件失败后可能把压缩物理内容当普通文件读取；
- fio 默认 invalidate cache，使所谓 warm-cache 实验实际混入冷读。

修复：

- 三条路径使用独立、逻辑 SHA-256 相同的文件；
- Hook 识别 GPUC 文件后显式清除 O_DIRECT；
- O_DIRECT fd 的 header 探测改用 `/proc/self/fd/<fd>` 的非 direct 描述符；
- warm 实验完整预读并设置 `--invalidate=0`，cold 实验单独运行；
- 保存每轮 header state、SHA-256、allocated bytes 和 fio JSON。

结论：2026-07-25 的 jobs=32 结果作废；正式结果是
`results/final/high_concurrency_warm_v100_20260729/`。

## 2. 多线程 CRC 错误

问题：

- 所有线程共享一个 raw io_uring；
- SQE 提交和 CQE 消费没有同步；
- 完成结果按返回顺序而非 `user_data` 归属，乱序 CQE 会对应到错误 block；
- 16 条 CUDA stream 在超过 8 个双流水线线程后循环重用。

修复：

- 一个 submit/drain transaction 使用进程级 mutex；
- 根据 CQE `user_data` 映射回目标 buffer；
- stream 池扩为 64，覆盖 32 个线程 × 2 条流水线；
- 64 MiB 的 4/32 线程边界测试与正式 75 样本均无 CRC 错误。

## 3. io_uring 与双流水线收益未经证实

消融结果中：

- no io_uring 比 full 高 0.23%；
- no pipeline 比 full 高 0.43%；
- 两者差异均不足以证明实际收益。

因此它们保留为可配置机制，但不再列为确定性能贡献。已证实的优化是 read-ahead
（约 11.1%）、batch（约 11.0%）和 pinned memory（约 2.6%）。

## 4. 默认批大小过大

真实编译扫描结果：

- 1 block：161.9 MiB/s；
- 2 blocks：177.8 MiB/s；
- 4 blocks：183.2 MiB/s；
- 8/16/32 blocks：约 182.3–183.1 MiB/s。

Hook 的 SGLZ 默认 batch 已改为 4；GPU 后端仍保留 32 块容量，供显式大 batch
和兼容测试使用。

## 5. LZ4 逐块同步过慢

问题：Hook 原本每个 128 KiB block 调一次 nvCOMP LZ4，同步开销使文本样例只有
29.4 MiB/s。

修复：顺序读取使用 4 块 batch 和逻辑 read-ahead，SHA-256/零数据回归通过，
吞吐提高到 81.0 MiB/s。继续扩大到 32 块时，由于 batch API 内每次仍执行
`cudaMalloc/cudaFree`，诊断轮出现严重退化，因此回退为 4。

后续正确方案是持久化 nvCOMP device/host pool，而不是盲目扩大 batch。

## 6. daemon 原子替换与元数据

问题：跨目录临时文件或直接覆盖可能造成崩溃后半文件、权限/xattr 丢失，以及
并发读者看见不一致内容。

修复：

- 同目录创建临时文件；
- 写完 header/index/data 后恢复 mode/owner/mtime/xattr；
- `fsync(temp)`、原子 `rename()`、`fsync(parent)`；
- rename 前比较源文件 size/mtime/ctime，变化则放弃替换；
- 已打开 fd 继续指向旧 inode，新 open 指向完整新 inode。

同一路径、未持有 flock 的 held/reopen reader 回归通过。

## 7. COMPRESSED 写语义

当前策略不是自动 copy-on-write，而是明确拒绝：

- `write/pwrite/writev/ftruncate/truncate` 等破坏性操作返回 `EROFS`；
- RAW 文件继续支持 O_APPEND、共享 offset、dup 和截断；
- 白名单文件不添加 GPUC header，rename 路径仍保证原子性和元数据。

该边界必须在部署说明中保留。

## 8. mmap 名称与实现不符

旧实现称为“按需解压”，但后台填充可能在应用提前访问时读到未完成页。
当前实现改为在 `mmap()` 返回前同步准备完整逻辑映射，优先保证立即访问任意页正确。
真正按访问页解压需要 userfaultfd，仍是后续工作。

## 9. 损坏格式防御

Hook 在 open 阶段验证：

- magic/version/state；
- block size、num_blocks、header_size；
- entry size；
- orig/comp length；
- offset 加法溢出、越界和表项重叠；
- CRC32。

损坏 header、非法 block table、超大字段、只读/只写 open 均有结构化回归。覆盖引导
fuzz 尚未完成，不能宣称所有恶意输入均已验证。

## 10. “GPU 释放 CPU”负结果

CPU 业务并发实验没有观察到优势：

- 4 workers：CPU LZ4 保留 87.5%，GPU LZ4 保留 87.1%；
- 1 worker：CPU LZ4 保留 50.1%，GPU LZ4 保留 48.6%。

同步 CUDA 提交线程仍占用共享核心。后续需使用独立服务进程/worker 和异步完成机制，
在重测前不得把“释放 CPU”作为已完成贡献。
