# GPUC 决赛后续优化路线

依据 2026-07-29 V100 正式实验排序。已完成事项见
阶段性任务清单暂存于 [`../tmp/FINAL_TODO.md`](../tmp/FINAL_TODO.md)，原始证据见
`results/final/`。

## P0：展示前必须完成

1. 只使用 `docs/EXPERIMENTAL_REPORT.md` 的有效结果制作图表；
2. PPT 明确区分 warm/cold/direct，删除旧 99.8% 与伪 O_DIRECT，只引用新版
   对齐格式的 SATA/ext4 direct 结果；
3. PPT 把 mmap 写成“同步完整逻辑映射”，不是按需页解压；
4. “GPU 释放 CPU”只使用同吞吐同亲和性的长期 worker 结果，旧同步负结果作为
   优化前历史；
5. 视频只演示可复现的 build、正确性、原子 daemon 替换和结果读取。

## 已完成：LZ4 持久化资源池

长期 worker、持久 CUDA stream/event/device buffer、pinned host buffer 和
32-block read-ahead 已完成。Linux headers 五轮均值从旧正式值 81.0 提升到
178.6 MiB/s；该整体结果不能单项归因，文件读取仍远慢于 Baseline。

实施：

- 在 `gpu_lz4_init()` 预分配 packed input/output、pointer arrays、length/status 和
  nvCOMP temp buffer；
- 每个 CUDA stream 使用独立槽位，并增加无冲突租约；
- D2H 只复制实际输出；
- 增加 1/2/4/8/16/32 LZ4 batch 扫描与并发正确性测试。

验收：

- 同一 Linux headers 输入、5 次重复；
- 无 CRC/SHA256 错误；
- 目标先达到或超过 SGLZ 107.8 MiB/s，再讨论默认后端切换。

## 已完成：进程内长期 CPU 卸载架构

证据：固定约 4096 MiB/s 后，GPU 额外主机 CPU 约 0.403 core，CPU 为
0.566 core；同 core 争用时 GPU/CPU 分别保留 97.17%/89.85% 业务吞吐。

实施：

- daemon 或独立 GPU worker 长期持有 CUDA context；
- 应用 Hook 通过 Unix socket/共享内存提交请求；
- 使用 eventfd/futex 完成通知，应用线程不忙等；
- 记录业务线程与服务进程的独立 CPU user/sys；
- 增加 GPU 空闲、GPU 繁忙和多租户三个场景。

验收：

- 同一 LZ4 数据格式；
- 业务吞吐、解压吞吐、CPU core-seconds、GPU util、功耗和 J/GB 全量记录；
- 只有 95% CI 不跨越 0 的业务提升才称为“释放 CPU”。

## P1：高并发饱和

证据：SGLZ 在 16 线程达到 381.6 MiB/s，32 线程回落至 348.8 MiB/s。

实施：

- NVTX/CUPTI 分解 pread、H2D、kernel、D2H、CRC 和锁等待；
- 分离每线程 pinned buffer、io_uring mutex 和 CUDA stream 的贡献；
- 测 8/16/24/32 线程及不同 CPU affinity；
- 若单进程 64 stream 资源占用过大，改为有界 stream pool + 请求队列。

## P2：userfaultfd mmap

当前同步方案正确但需要完整准备。

实施：

- `PROT_NONE` 或 userfaultfd 注册逻辑映射；
- 缺页时按 block 解压并唤醒等待线程；
- 支持并发 fault 合并、缓存回收、unmap 和进程退出；
- 在内核禁用 userfaultfd 时明确回退同步方案。

验收：返回延迟、首次页、随机页、全量扫描、并发 fault 和 RSS 峰值分别报告。

## 已完成软件路径：格式与 O_DIRECT

- header/index 已 padding 到 4 KiB；
- 每块 offset 与物理读取 span 已对齐；
- entry 同时保存真实 `comp_len` 与 padded span；
- pinned host buffer 满足 direct I/O 对齐；
- `F_GETFL`、内容和 fio 0 error 已验证。

当前正式结果来自 SATA/ext4；独占 NVMe 性能仍需有挂载权限的环境复跑。

## P2：真实 workload 与 break-even

- 选择有 URL、版本、许可证和 SHA-256 的公开日志/文本/模型数据集；
- 记录压缩耗时，计算 N 次读取后的总时间和能耗；
- 绘制文件大小 × allocated ratio × 并发数的 break-even；
- btrfs zstd 只在独立压缩卷验证 `compsize` 生效后对比；
- 不再把随机字节文件命名为 ImageNet 或真实业务。
