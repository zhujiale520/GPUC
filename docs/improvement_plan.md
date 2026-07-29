# GPUC 决赛后续优化路线

依据 2026-07-29 V100 正式实验排序。已完成事项见
[`FINAL_TODO.md`](FINAL_TODO.md)，原始证据见 `results/final/`。

## P0：展示前必须完成

1. 只使用 `docs/EXPERIMENTAL_REPORT.md` 的有效结果制作图表；
2. PPT 明确区分 warm/cold cache，删除旧 99.8% 与伪 O_DIRECT；
3. PPT 把 mmap 写成“同步完整逻辑映射”，不是按需页解压；
4. 将“GPU 释放 CPU”展示为负结果与下一步，不制作正向宣传图；
5. 视频只演示可复现的 build、正确性、原子 daemon 替换和结果读取。

## P1：LZ4 持久化资源池

证据：4 块 batch 将 LZ4 从 29.4 提高到 81.0 MiB/s，但当前 batch 函数仍为每批
分配和释放 device memory；直接扩大到 32 块出现严重退化。

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

## P1：真正的 CPU 卸载架构

证据：同步 API 下 GPU 业务吞吐不优于 CPU。

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

## P2：格式与 O_DIRECT

当前格式不支持真正 O_DIRECT。若比赛后确需支持：

- header/index padding 到 4 KiB；
- 每块 offset 与 I/O length 对齐；
- 保存真实 compressed length 与 padded length；
- 对齐 host buffer，并在解压前剥离 padding；
- 冷缓存 direct 实验只在内核实际接受 O_DIRECT 后发布。

## P2：真实 workload 与 break-even

- 选择有 URL、版本、许可证和 SHA-256 的公开日志/文本/模型数据集；
- 记录压缩耗时，计算 N 次读取后的总时间和能耗；
- 绘制文件大小 × allocated ratio × 并发数的 break-even；
- btrfs zstd 只在独立压缩卷验证 `compsize` 生效后对比；
- 不再把随机字节文件命名为 ImageNet 或真实业务。
