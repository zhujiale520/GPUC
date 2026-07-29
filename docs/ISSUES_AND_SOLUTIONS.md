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

## 8. mmap 从同步完整填充改为 userfaultfd

旧后台填充会在应用提前访问时暴露未完成页，之后改成返回前同步完整填充，保证了
正确性但 256 MiB COMPRESSED 的 `mmap()` 返回约 1.21 s。

当前默认通过 userfaultfd 注册 missing fault，handler 根据 fault 地址定位并填充
128 KiB GPUC block。256 MiB V100 五轮中 `mmap()` 返回为
0.215 ± 0.011 ms，首次 fault 为 146.502 ± 3.836 ms，完整扫描为
5651.449 ± 367.254 ms，逐页 pattern mismatch 为 0。它解决了返回延迟，不代表
完整解压成本消失；8 扫描线程也没有稳定线性加速。

不支持 userfaultfd 的内核自动回退同步模式；`GPUC_MMAP_MODE=userfaultfd` 可要求
严格失败。受管文件的 `MAP_SHARED`/`MAP_FIXED` 返回 `EOPNOTSUPP`。

## 9. 损坏格式防御

Hook 在 open 阶段验证：

- magic/version/state；
- block size、num_blocks、header_size；
- entry size；
- orig/comp length；
- offset 加法溢出、越界和表项重叠；
- CRC32。

损坏 header、非法 block table、超大字段、只读/只写 open 均有结构化回归，并有
2000 个确定性变异格式 smoke。覆盖引导 fuzz 尚未完成，不能宣称所有恶意输入均已
验证。

## 10. “GPU 释放 CPU”从负结果到有边界的正结果

旧同步 API 在未固定处理量和 worker affinity 时没有观察到优势，且 GPU worker
可能偷用空闲核心，因此旧的 87.5%/87.1% 结果只保留为历史诊断。

修复包括长期请求 worker、持久 CUDA/pinned buffer、blocking sync、worker
affinity 和固定约 4096 MiB/s 的 CPU/GPU公平口径。五轮结果：

- 与业务争用 core 0：CPU/GPU 分别保留 89.85%/97.17%，95% CI 不重叠；
- 解压隔离到 core 4：GPU 额外主机 CPU 约 0.403 core，CPU 为 0.566 core；
- SQLite：GPU 相对 CPU 路径 QPS 高约 7.3%，p99 低约 50.5%。

因此可以陈述固定吞吐下 GPU offload 减少主机 CPU 并减轻业务干扰，但不能陈述
GPU 绝对吞吐高于 CPU、DRAM 容量下降或压缩文件读取快于 Baseline。

## 11. 故障恢复缺少可重复证据

仅写“原子 rename”无法证明中途失败不会损坏原文件。本轮为 CPU/GPU Daemon 增加
仅测试使用的块计数故障点，`tests/fault_recovery.sh` 无需 root 即可复现：

- 写两块后注入 ENOSPC，原 RAW 和 SHA 保持，正常失败路径清理临时文件；
- 写一块后暂停并 SIGKILL，原 inode 保持；
- 重启覆盖残留临时文件并生成可回读 COMPRESSED；
- 隐藏 GPU 后验证 CPU fallback SHA；
- `/dev/full` 验证内核写错误向上传播。

真实 GPU reset 和掉电未在共享机器执行，不能写成已覆盖。

## 12. 测试很多但缺覆盖率门槛

新增 `tests/coverage_cpu.sh`，使用 GCC 自带 gcov，避免依赖未安装的 lcov。正式
结果中 Hook/CPU Daemon/CPU SGLZ/CPU LZ4 行覆盖率分别为
41.38%/62.15%/85.52%/70.83%，CI 要求 Hook 不低于 35%。CUDA kernel 继续由
功能、CRC/SHA 和集成测试覆盖，不把 CPU gcov 数字外推到 GPU 代码。
