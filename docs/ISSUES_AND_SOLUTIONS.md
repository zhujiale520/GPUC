# GPUC 关键问题与解决方法

本文只记录已由源码和截至 2026-07-31 的回归验证问题。性能数值以
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

第一阶段修复：顺序读取使用 batch 和逻辑 read-ahead，并在解压侧建立长期 worker
与持久 device/pinned-host pool。

第二阶段审计发现 Daemon 的 `gpu_lz4_compress_batch()` 虽接收 32 个 block，
内部仍循环调用单块 API，每块都 H2D/kernel/D2H/synchronize，并非真正 batch。
当前新增独立持久 compression pool，把输入、device pointer array、长度和输出
一次提交给 `nvcompBatchedLZ4CompressAsync`，整批只同步一次；
`GPUC_LZ4_SERIAL_COMPRESS=1` 保留旧路径作为消融。

512 MiB 工作集五轮中，旧 serial 为 55.821±0.313 MiB/s，真正 batch 在
1024 MiB/s 限速下稳定达到 1023.984 MiB/s，至少提高 18.34 倍，压缩率与逐块
CPU 解压校验一致。但同为 1024 MiB/s 时 GPU/CPU 主机 CPU 为
0.365/0.276 core，因此这项修复是吞吐优化，不能包装成压缩侧 CPU 卸载收益。

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

## 13. 单一高压缩率、高吞吐点不能代表适用边界

问题：早期资源卸载实验只使用高可压缩输入和约 4096 MiB/s 固定吞吐。它能够
证明一个工作点，却不能回答低压缩率、低吞吐是否仍有业务收益，也无法区分“达到
固定处理量”与“已经饱和但仍拿业务数据比较”。

修复：新增确定性的 0%/50%/100% 可压缩页生成器，以及
`tests/offload_sensitivity.sh`。实验覆盖 1024/2048/4096 MiB/s × 三档压缩率 ×
CPU/GPU 各五轮，并记录实际存储比、目标达成率、业务保留率和 submit/worker
线程 CPU。基准五轮加 90 个 CPU/GPU 样本共 95 条记录。

结果边界：

- 七个 CPU/GPU 均达到至少 99% 目标的公平组中，GPU 解压 host CPU 降低
  7.0%–55.4%；
- 业务差从 1024 MiB/s、不可压缩输入的 +0.132±0.630 pp，增长到
  4096 MiB/s、高可压缩输入的 +3.503±0.084 pp；前者以及 2048 MiB/s、
  不可压缩输入与零重叠，不能声称稳定业务收益；
- 4096 MiB/s 的不可压缩和 50% 可压缩组至少一条路径未达到 99% 目标，只能
  报告为饱和边界，不能作固定吞吐比较。

随后补充的512 MiB whole-system PCM代表组均达到约99.9%目标吞吐。GPU相对CPU
总DRAM差在1024 MiB/s不可压缩、2048 MiB/s+50%、4096 MiB/s高可压缩输入下
分别为−0.11%、−5.69%、−47.42%，同时GPU RSS高5.80%–8.92%。这进一步证明
DRAM收益随压缩率和吞吐变化，最高档数字不能外推，也不能改写为内存容量下降。

压缩侧另用 `tests/lz4_compress_sensitivity.sh` 测量不限速峰值。0%/50%/100%
可压缩页下，GPU batch 只有单核 CPU liblz4 吞吐的 8.7%/7.3%/16.6%。因此当前
GPU 压缩实现的较低 host CPU 伴随明显更低处理量，不能作为公平卸载收益；压缩侧
仍是需要优化的负结果。

## 14. SQLite 并行业务收益不等于数据库自身加速

问题：SQLite 与固定吞吐解压任务并行时，GPU 相对 CPU 路径 QPS 高 7.3%、p99
低 50.5%。该实验回答的是 CPU 资源竞争，不能证明 SQLite 数据库放入压缩对象后
查询会更快。

审计修复：旧runner设置了LZ4环境变量，却调用只生成SGLZ的CPU daemon，文件头
算法ID为1。旧329.86/21.79 QPS及fixed32结果已标为历史无效。新runner改用支持
LZ4的daemon，并在正式实验前强制校验`comp_algo=2`，防止标签再次漂移。

优化：新增`GPUC_LZ4_SMALL_READ_CPU_BLOCKS`。默认应用请求只覆盖一个128 KiB
block时走CPU liblz4，批量请求继续GPU卸载；设置0可恢复严格GPU-only。真实LZ4
五轮中，严格GPU-only为55.67 QPS、p99 24.47 ms，混合策略为108.33 QPS、
p99 11.62 ms，即QPS提高94.58%、p99降低52.52%。但普通文件仍为22197.22 QPS，
因此只证明显著缓解小请求CUDA固定开销。

结论：当前128 KiB block与用户态Hook不适合高性能SQLite点查；混合分流是明确的
CPU/GPU策略，不能冒充GPU加速。可写数据库仍需要文件系统/DM层集成。

## 15. LZ4 每block H2D提交开销

问题：D2H已经合并，但解压输入仍对batch中的每个压缩block单独调用
`cudaMemcpyAsync`，大量小DMA提交消耗host orchestration时间。

修复：长期decompression pool增加pinned input staging buffer；同一batch先在host
连续打包，再一次H2D。`GPUC_H2D_COALESCE=0`保留旧路径用于消融。

验证：512 MiB工作集、128 blocks/batch五轮中，吞吐4805.13→5275.91 MiB/s
（+9.80%），H2D 0.2713→0.0393 ms（-85.51%）；GPU微基准约6.01→7.63
GiB/s。CPU仍约11.48 GiB/s，所以该修复收窄但没有反转绝对吞吐差距。
