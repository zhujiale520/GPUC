# proj35 - 基于GPU的服务资源卸载技术探索

## 题目信息
- **选题编号**: proj35
- **题目内容**: 基于GPU的服务资源卸载技术探索（Exploration of GPU-based Service Resource Off-loading Technology）
- **高校名称**: 西安交通大学
- **队伍ID**: T2026106989910286
- **队伍名**: 404notfound

---

## 项目概述

本项目在**不修改内核、不改动现有文件系统（ext4/xfs）**的前提下，通过用户态
`LD_PRELOAD` 拦截层为指定动态链接进程提供 GPU offload 存储压缩：

- **写路径**：应用写入 RAW，后台 Daemon 原子转换为只读压缩对象
- **读路径**：加载 Hook 的应用对压缩文件自动调用 GPU/CPU 解压
- **mmap 路径**：`userfaultfd` 按 128 KiB block 缺页填充，内核不支持时同步回退
- **可插拔压缩后端**：默认 SGLZ（不依赖 nvCOMP），可选 `GPUC_ALGO=lz4` 启用 NVIDIA nvCOMP LZ4，文本类数据压缩率从 ~82% 降至 ~39%
- **非侵入式**：动态链接应用无需重新编译，但静态程序、直接 syscall 和应用
  自提交 io_uring 不在透明覆盖范围

压缩完成后的 COMPRESSED/INLINE 文件采用明确的**只读归档模型**，破坏性修改返回
`EROFS`。完整设计、实现与能力边界见[项目设计方案](docs/项目设计方案.md)。

---

## 快速开始（新主机）

```bash
# 1. 环境检查（自动检测 GPU、CUDA、依赖项）
bash scripts/check_env.sh

# 2. 编译（Makefile 自动检测 GPU 计算能力）
make clean && make all

# 3. 运行单元测试 + 集成测试
make test

# 4. 一键 DEMO（写入 → 压缩 → 透明读取 → MD5 校验）
bash scripts/demo.sh

# 5. fio 性能基准测试
bash tests/benchmark_fio.sh
```

### 手动分步体验

```bash
# 创建测试文件并压缩
export LD_PRELOAD="$PWD/bin/libgpuhook.so"
dd if=/dev/zero of=/tmp/test.bin bs=1M count=100
unset LD_PRELOAD
./bin/gpu_compress_daemon /tmp/

# 透明读取压缩文件
export LD_PRELOAD="$PWD/bin/libgpuhook.so"
dd if=/tmp/test.bin of=/dev/null bs=1M
unset LD_PRELOAD
```

### 使用 LZ4 后端（可选）

```bash
# 写入数据后，用 GPUC_ALGO=lz4 启动 Daemon，启用 NVIDIA nvCOMP LZ4 压缩
export LD_PRELOAD="$PWD/bin/libgpuhook.so"
dd if=/usr/include of=/tmp/headers.tar bs=1M
unset LD_PRELOAD

GPUC_ALGO=lz4 ./bin/gpu_compress_daemon /tmp/

# 读取时自动解压，无需额外参数
export LD_PRELOAD="$PWD/bin/libgpuhook.so"
cat /tmp/headers.tar | sha256sum
unset LD_PRELOAD
```

---

## 系统架构

```
┌─────────────────────────────────────────────────────────┐
│  用户态应用 (fio, cp, dd, 数据库...)                      │
├─────────────────────────────────────────────────────────┤
│  LD_PRELOAD 拦截层 (libgpuhook.so)                       │
│     ├─ open()  → 新文件自动附加 RAW header               │
│     ├─ read()  → 查索引 → 批量 GPU 解压 → 返回原始数据    │
│     ├─ mmap()  → userfaultfd 按块填充，必要时同步回退      │
│     ├─ write() → 直接透传（不压缩）                       │
│     └─ fstat() → 报告逻辑大小（隐藏物理稀疏大小）         │
├─────────────────────────────────────────────────────────┤
│  Offline Daemon (gpu_compress_daemon)                    │
│     ├─ 扫描目录 → 过滤 RAW 文件                          │
│     ├─ 逐块 GPU 压缩（128KB/block，batch=32）             │
│     ├─ 写临时文件 → atomic rename 替换                   │
│     └─ 保持 128KB 稀疏对齐，支持随机读                    │
├─────────────────────────────────────────────────────────┤
│  ext4 / xfs（不改文件系统，按进程启用）                   │
└─────────────────────────────────────────────────────────┘
```

---

## 核心特性

### GPUC 文件格式

| 字段 | 说明 |
|------|------|
| Magic | `0x47505543` ("GPUC") |
| 块大小 | 固定 128 KB |
| 布局 | Header + Block Index Table + 稀疏对齐的压缩数据 |
| 状态机 | RAW → (Daemon 压缩) → COMPRESSED / INLINE |

### SGLZ 压缩算法（CUDA，默认后端）

- 128 KB = 32 × 4 KB chunks，每 chunk 独立压缩
- LZ77 变体，3-byte hash 滑动窗口（2048 B）
- `0xFFFF` 标记未压缩 chunk（不可压缩数据的 fallback）
- 不依赖 nvCOMP，体现 GPU **通用算力**

### LZ4 压缩算法（CUDA，可选后端）

- 通过 `GPUC_ALGO=lz4` 启用，调用 **NVIDIA nvCOMP** batched LZ4 API
- 每个 128 KB block 作为独立 chunk 压缩，输出 `[1B flag][payload]` 格式
- 文本类数据压缩率显著优于 SGLZ（Linux headers：82.5% → 38.6%）
- CPU fallback 基于系统 liblz4，保证 GPU 不可用时仍可读取

### 核心优化汇总

| 优化项 | 说明 | 量化效果 |
|--------|------|---------|
| **Daemon Compress 内存池** | 预分配 8.4 MB device 内存，消除 `cudaMalloc/cudaFree` | 压缩耗时 2.14s（512MB zero，234 MB/s） |
| **小文件内联** | ≤1KB 文件直接内联到 header 后 | 读取延迟 6.6-9.5 us（平均 8.4 us） |
| **Batch GPU Decompress** | 一次解压 16 blocks（512 chunks） | 顺序读 458 MB/s（128k bs） |
| **Device Memory Pool** | 预分配 decompress 内存池（双缓冲） | 零分配延迟 |
| **双缓冲流水线** | 两套 CUDA stream 重叠 I/O 与 GPU 计算 | 隐藏 H2D/D2H 延迟 |
| **io_uring 异步 I/O** | Raw syscall 批量提交 pread | 减少 syscall 次数 |
| **自适应 Read-Ahead** | 顺序检测 + 动态窗口 0→4→8→16 blocks | 提升顺序读吞吐 |
| **Pinned Memory** | TLS 缓冲区改用 `cudaHostAlloc` | 消除 driver 中转 memcpy |
| **CRC32 校验** | 每 block 存储 CRC32，hook 解压后验证 | 数据完整性保障 |
| **紧凑格式解压** | GPU kernel 内通过索引表直接定位紧凑数据 | 消除 CPU 侧 `memcpy` |

### 拦截的系统调用（25+ 个）

```
open / open64 / creat / openat / openat64
read / write / pread64 / pwrite64 / readv / writev
lseek / lseek64 / close / dup / dup2 / dup3
mmap / munmap / msync
__fxstat / __fxstat64 / __xstat / __xstat64 / __lxstat / __lxstat64
ftruncate / truncate / sendfile
```

---

## 最终实验结论

正式结果来自 Tesla V100 与 RTX 4090，完整统计和边界见
[实验结果报告](docs/实验结果报告.md)及
[4090 缺口分析](results/final/RTX4090_GAP_ANALYSIS_20260807.md)。

| 证据 | RTX 4090 结果 | 正确表述 |
|---|---|---|
| 4 GiB/s 高可压缩解压压力 | GPU 相对 CPU 多保留 13.05% 业务吞吐；解压进程 CPU 时间降低 96.4% | GPU 卸载在该工作点减轻主机 CPU 竞争 |
| SQLite 并行业务 | QPS +11.21%，p99 -81.66%，但仍低于无解压 baseline 5.14% | 释放 CPU 可改善并行业务，不等于数据库文件本身被 GPU 加速 |
| fio / Vdbench | fio 完整矩阵 465/465；Vdbench 50/50；逻辑 SHA 一致 | 两套工具验证端到端功能、退出和正确性 |
| 长期与故障 | 一小时读 error=0、前后 SHA 一致；故障恢复 5/5 | 支持持续稳定和确定性恢复；掉电/GPU reset 为隔离环境扩展项 |
| mmap | 60/60 mismatch=0；256 MiB 单/8线程扫描约 2.31/2.32 s | userfaultfd 兼容已验证，扫描没有线程扩展收益 |
| 4 KiB 随机压缩读 | 请求感知预读相对 legacy 提高约 31.7–32.0 倍 | 消除了固定 32-block 放大，但绝对性能仍低于普通文件 |

低压缩率、压缩侧峰值、PG2600、Btrfs 与 4090 PCM 中的负结果均作为适用边界
保留；本项目不声称压缩文件读取普遍快于普通文件，也不声称已经实现生产级
DM/Btrfs/ZFS 压缩层。

---

## 目录结构

```
├── include/
│   ├── file_header.h        # GPUC 文件格式定义
│   ├── gpu_compress_api.h   # C API（GPU/CPU 后端）
│   └── lz4_minimal.h        # liblz4 最小函数声明（避免安装 dev 包）
├── src/
│   ├── hook.c               # LD_PRELOAD 拦截层 (~3600 行)
│   ├── gpu_compress.cu      # CUDA SGLZ 压缩/解压 (~716 行)
│   ├── gpu_lz4.cu           # CUDA LZ4 压缩/解压 (~1040 行)
│   ├── cpu_compress.c       # CPU SGLZ 压缩/解压 (~279 行)
│   ├── cpu_lz4.c            # CPU LZ4 解压 (~100 行)
│   ├── daemon.c             # 离线压缩 Daemon (~728 行)
│   ├── cpu_daemon.c         # CPU 版 Daemon
│   └── gpu_compress.cuh     # CUDA 内部头文件
├── tests/
│   ├── benchmark_comprehensive.sh      # 全面性能基准测试
│   ├── benchmark_fio.sh               # fio 基准测试
│   ├── ablation_study.sh              # 消融实验（逐项关闭优化）
│   ├── batch_size_sweep.sh            # Batch Size 敏感性扫描
│   ├── real_workload_study.sh         # 真实数据 workload 测试
│   ├── nvcomp_lz4.sh                  # nvCOMP LZ4 后端集成测试
│   ├── first_io_latency.sh            # Hook 首次 I/O 延迟测试
│   ├── metadata_perf.sh               # stat/ls/find 性能测试
│   ├── massive_small_files.sh         # 海量小文件批量场景
│   ├── power_efficiency.sh            # GPU 解压能耗效率测试
│   ├── mem_pressure_scan.sh           # GPU 显存压力扫描
│   ├── odirect_read.sh                # O_DIRECT 压缩读测试
│   ├── write_read_consistency.sh      # 写后读一致性验证
│   ├── long_term_stability.sh         # 默认 1 小时稳定性与 SHA 测试
│   ├── fault_recovery.sh              # ENOSPC/SIGKILL/重启/降级测试
│   ├── coverage_cpu.sh                # CPU 路径 gcov 覆盖率门槛
│   ├── random_read_small_bs.sh        # 小 bs 随机读测试
│   ├── mmap_size_sweep.sh             # mmap 不同文件大小测试
│   ├── multithread_jobs32.sh          # 32 线程并发扩展性测试
│   ├── write_path_overhead.sh         # 写路径 overhead 测试
│   ├── gpu_compute_load_decompress.sh # GPU 计算负载下解压测试
│   ├── daemon_concurrent_safety.sh    # Daemon 并发安全验证
│   ├── btrfs_compare.sh               # btrfs zstd 对比（需 root）
│   ├── generate_figures.py            # 自动生成实验图表
│   ├── test_inline.sh                 # 小文件内联测试
│   ├── test_integration.sh            # 集成测试
│   └── test_mixed_compressibility.sh  # 混合可压缩性测试
├── docs/
│   ├── 项目设计方案.md                # 设计、实现、代码、问题与来源说明
│   ├── 项目设计方案.docx              # 可编辑 Word 版本
│   ├── 实验结果报告.md                # V100 与 RTX 4090 完整实验结果
│   ├── 实验结果报告.docx              # 可编辑 Word 版本
│   ├── 实验复现指南.md                # 环境、构建与实验复现步骤
│   ├── 实验复现指南.docx              # 可编辑 Word 版本
│   ├── architecture.png               # 答辩用浅色架构图
│   └── architecture.svg               # 可编辑矢量架构图
├── ppt/
│   ├── PPT_OUTLINE.md                 # 最终答辩 PPT 逐页制作大纲
│   └── *.pptx / *.pdf                 # 保留的历史答辩稿
├── video/
│   ├── README.md                      # 视频目录说明
│   └── VIDEO_SCRIPT.md                # 最终演示视频脚本
├── scripts/
│   ├── check_env.sh           # 新主机环境检查
│   ├── demo.sh                # 一键演示
│   ├── demo_presentation.sh   # 面向汇报的完整演示脚本
│   └── monitor_resources.sh   # 资源监控
├── LICENSE                  # 源代码许可证（Apache-2.0）
├── LICENSE-docs             # 文档许可证（CC BY-SA 4.0）
├── Makefile
└── README.md
```

---

## 文档与答辩材料

- [项目设计方案](docs/项目设计方案.md) / [Word 版](docs/项目设计方案.docx) — 设计思路、实现与代码说明、研发问题与解决方法、第三方及 AI 使用说明
- [实验结果报告](docs/实验结果报告.md) / [Word 版](docs/实验结果报告.docx) — V100 与 RTX 4090 的完整数据、统计口径和适用范围
- [实验复现指南](docs/实验复现指南.md) / [Word 版](docs/实验复现指南.docx) — 环境检查、构建、功能验证和实验复现入口
- [PPT 制作大纲](ppt/PPT_OUTLINE.md) — 队员分工、开发进度、技术路线和答辩证据编排
- [演示视频脚本](video/VIDEO_SCRIPT.md) — 运行环境、源码与功能演示、正式结果说明
- [LICENSE](LICENSE) / [LICENSE-docs](LICENSE-docs) — 源代码与文档许可证

---

## 技术平台

- GPU: 已测试 Tesla V100-SXM2-32GB 与 GeForce RTX 4090；RTX 3060/4060/5060 为赛题指定但尚未实测
- CPU: 已测试 x86_64；华为鲲鹏 920/AArch64 为目标平台但尚未实测
- 编程框架: CUDA SDK 12.8
- 文件系统: ext4

---

## 已知限制

| 限制 | 说明 |
|------|------|
| 应用覆盖 | 仅加载 Hook 的动态链接 libc I/O；静态/直接 syscall/应用 io_uring 不覆盖 |
| 压缩对象修改 | COMPRESSED/INLINE 只读，破坏性修改返回 `EROFS` |
| `mmap` | 支持只读 `MAP_PRIVATE` 完整解除；共享/固定/部分 munmap/跨 fork 不支持 |
| `O_DIRECT` | 新版对齐格式已支持，要求用户缓冲区页对齐；正式 NVMe 性能未测 |
| GPU 选择 | `CUDA_VISIBLE_DEVICES` 可选择一个 GPU；不支持并发多 GPU 分片 |
| GPU 供应商 | 当前只支持 NVIDIA CUDA；其他供应商后端暂缓 |
| GPU 共享性能 | GPU 高负载时实时性能下降约 82%（458 vs 80 MB/s） |

---

## 参考资料

- [NVIDIA nvCOMP](https://github.com/NVIDIA/CUDALibrarySamples/tree/master/nvCOMP)
- [ZFS Hardware Acceleration with QAT](https://openzfs.org/wiki/ZFS_Hardware_Acceleration_with_QAT)
- [XRP: In-Kernel Storage Functions with eBPF](https://github.com/xrp-project/XRP)

---

## 开源协议与合规声明

- **源代码**：采用 [Apache License 2.0](LICENSE)。
- **技术文档 / 答辩材料**：采用 [CC BY-SA 4.0](LICENSE-docs)。
- **第三方依赖与非本队来源**：见[项目设计方案](docs/项目设计方案.md)中的“非本队来源与第三方说明”。
- **AI 工具使用说明**：见 [docs/AI_TOOL_DECLARATION.md](docs/AI_TOOL_DECLARATION.md)。
- **原创性声明**：本项目为原创，未基于往届作品或开源项目。

---

> 比赛截止时间：2026-06-29
> 参赛项目：2026年全国大学生计算机系统能力大赛-操作系统设计赛(全国)-OS功能挑战赛道
