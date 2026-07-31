# 公开参考与本项目结果的可比边界

> 核对日期：2026-07-30。公开资料只用于确定实现语义和合理测试维度，不用不同
> GPU、CPU、数据集、缓存状态或软件版本的数字替代本项目实测。

## 1. 可追溯参考

| 参考 | 可确认事实 | 对本项目的作用 | 不能推出 |
|---|---|---|---|
| NVIDIA nvCOMP LZ4 | LZ4 将输入分块并并发处理；低层 batched API 用一次调用处理多个小输入，官方说明这比逐个调用更高效 | 支持将旧逐块同步改成真正的 `nvcompBatchedLZ4CompressAsync` | 不能用官方其他 GPU 的吞吐作为 V100 成绩 |
| Btrfs Compression | extent 透明压缩；数据按 128 KiB chunk；zstd:3 为默认 zstd level；compress-force 仍会对膨胀块回退 RAW | 本项目 Btrfs 基线采用 128 KiB、zstd:3，并记录空间与 fio | 不能把 Btrfs 文档的定性描述写成 GPUC 性能优势 |
| OpenZFS Compression | record 级透明压缩；LZ4 偏速度、zstd 偏压缩率；仅新写数据受属性变化影响；可查询 logical/used/compressratio | 确定未来 ZFS 公平基线必须重写数据并核验物理占用 | 当前无 zpool 实验，不能声称胜过 ZFS |
| Linux DM persistent-data | transaction manager 使用 COW；commit 保证先刷新数据再写 superblock，掉电恢复到最近提交状态 | 约束未来变长块映射和崩溃一致性设计 | 当前用户态原子 rename 不等价于 DM metadata transaction |

来源：

- <https://docs.nvidia.com/cuda/archive/13.1.0/nvcomp/lz4.html>
- <https://docs.nvidia.com/cuda/nvcomp/samples/lowlevel_c_quickstart.html>
- <https://btrfs.readthedocs.io/en/latest/Compression.html>
- <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Compression.html>
- <https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/persistent-data.html>

## 2. 官方示例数字如何使用

nvCOMP 当前 Python API 示例对约 1.205 MB 的 Moby-Dick 文本给出 LZ4
`824,829 / 1,205,404 = 68.4%`。这只是官方示例数据，不是性能基准；它和本项目
Linux headers、Gutenberg、日志/ELF 数据的 block size、容器开销和版本均不同。
报告可以引用它说明“压缩率依赖数据”，但不得做排名或计算提升百分比。

示例来源：
<https://docs.nvidia.com/cuda/nvcomp/samples/nvcomp.html>

## 3. 本项目必须以本机实测回答的问题

- 同一输入、128 KiB block、相同逻辑吞吐下，CPU liblz4 与 V100 nvCOMP 的主机
  CPU、DRAM、RSS、GPU board power；
- 逐块同步与真正批量压缩的严格 A/B；
- ext4 plain、ext4+GPUC LZ4、Btrfs zstd:3 使用同一源文件和 fio 参数；
- 所有路径的逻辑 SHA-256、一致的 warm/cold 定义、五轮及 95% CI；
- 当前 GPUC 压缩读取仍慢于 plain baseline 时，必须报告负结果。

因此公开资料是“外部锚点”，`results/final/` 才是本项目可用于答辩的定量证据。
