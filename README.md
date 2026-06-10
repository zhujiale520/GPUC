# proj35 - 基于GPU的服务资源卸载技术探索

## 题目信息
- **选题编号**: proj35
- **题目内容**: 基于GPU的服务资源卸载技术探索（Exploration of GPU-based Service Resource Off-loading Technology）
- **高校名称**: 西安交通大学
- **队伍ID**: T2026106989910286
- **队伍名**: 404notfound

---

## 项目概述

本项目在**不修改内核、不改动现有文件系统（ext4/xfs）**的前提下，通过用户态 `LD_PRELOAD` 透明拦截层实现 GPU offload 存储压缩：

- **写路径**：应用透明写入，后台 Daemon 异步 GPU 压缩
- **读路径**：对压缩文件自动调用 GPU 实时解压，用户完全无感知
- **mmap 路径**：新增 mmap/munmap/msync 拦截，压缩文件可透明映射
- **非侵入式**：基于 `LD_PRELOAD`，现有应用无需重新编译

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

---

## 系统架构

```
┌─────────────────────────────────────────────────────────┐
│  用户态应用 (fio, cp, dd, 数据库...)                      │
├─────────────────────────────────────────────────────────┤
│  LD_PRELOAD 拦截层 (libgpuhook.so)                       │
│     ├─ open()  → 新文件自动附加 RAW header               │
│     ├─ read()  → 查索引 → 批量 GPU 解压 → 返回原始数据    │
│     ├─ mmap()  → COMPRESSED 文件预解压到匿名内存          │
│     ├─ write() → 直接透传（不压缩）                       │
│     └─ fstat() → 报告逻辑大小（隐藏物理稀疏大小）         │
├─────────────────────────────────────────────────────────┤
│  Offline Daemon (gpu_compress_daemon)                    │
│     ├─ 扫描目录 → 过滤 RAW 文件                          │
│     ├─ 逐块 GPU 压缩（128KB/block，batch=32）             │
│     ├─ 写临时文件 → atomic rename 替换                   │
│     └─ 保持 128KB 稀疏对齐，支持随机读                    │
├─────────────────────────────────────────────────────────┤
│  ext4 / xfs（完全不改，透明叠加）                         │
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

### SGLZ 压缩算法（CUDA）

- 128 KB = 32 × 4 KB chunks，每 chunk 独立压缩
- LZ77 变体，3-byte hash 滑动窗口（2048 B）
- `0xFFFF` 标记未压缩 chunk（不可压缩数据的 fallback）
- 不依赖 nvCOMP，体现 GPU **通用算力**

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

## 性能数据

### fio 顺序读 128k（Tesla V100, 512MB, page cache 命中）

| 场景 | zero | rand | rep |
|------|------|------|-----|
| Baseline | 450.9 MB/s | 448.0 MB/s | 451.5 MB/s |
| Hook RAW | 451.7 MB/s | 443.0 MB/s | 447.2 MB/s |
| **GPU Compressed** | **458.3 MB/s** | **433.0 MB/s** | **442.4 MB/s** |

### 多线程并发读取（zero 数据, 128KB bs）

| 并发数 | Baseline | Hook RAW | GPU Compressed | 扩展比 |
|-------|---------|---------|---------------|--------|
| jobs=1 | 456.3 MB/s | 466.3 MB/s | 466.3 MB/s | 1.00x |
| jobs=4 | 1098.0 MB/s | 1101.8 MB/s | 1090.9 MB/s | 2.34x |
| jobs=8 | 1985.0 MB/s | 1997.2 MB/s | 1991.8 MB/s | 4.27x |
| jobs=16 | 3768.1 MB/s | 3792.1 MB/s | **3797.7 MB/s** | **8.14x** |

### 压缩效果

| 数据类型 | 压缩率 |
|---------|--------|
| 全零数据 | **6.3%** |
| 可压缩重复模式 | **6.3%** |
| 混合数据 | **53.1%** |
| 随机数据 | **100% (fallback)** |

---

## 目录结构

```
├── include/
│   ├── file_header.h        # GPUC 文件格式定义
│   └── gpu_compress_api.h   # C API（GPU/CPU 后端）
├── src/
│   ├── hook.c               # LD_PRELOAD 拦截层 (~2100 行)
│   ├── gpu_compress.cu      # CUDA 压缩/解压 (~580 行)
│   ├── cpu_compress.c       # CPU 压缩/解压 (~212 行)
│   ├── daemon.c             # 离线压缩 Daemon (~520 行)
│   ├── cpu_daemon.c         # CPU 版 Daemon
│   └── gpu_compress.cuh     # CUDA 内部头文件
├── tests/
│   ├── benchmark_comprehensive.sh      # 全面性能基准测试
│   ├── benchmark_fio.sh               # fio 基准测试
│   ├── ablation_study.sh              # 消融实验（逐项关闭优化）
│   ├── batch_size_sweep.sh            # Batch Size 敏感性扫描
│   ├── real_workload_study.sh         # 真实数据 workload 测试
│   ├── first_io_latency.sh            # Hook 首次 I/O 延迟测试
│   ├── metadata_perf.sh               # stat/ls/find 性能测试
│   ├── massive_small_files.sh         # 海量小文件批量场景
│   ├── power_efficiency.sh            # GPU 解压能耗效率测试
│   ├── mem_pressure_scan.sh           # GPU 显存压力扫描
│   ├── odirect_read.sh                # O_DIRECT 压缩读测试
│   ├── write_read_consistency.sh      # 写后读一致性验证
│   ├── long_term_stability.sh         # 30 分钟长时间稳定性测试
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
│   ├── architecture.md      # 架构文档
│   ├── architecture.png     # 架构图
│   └── deployment.md        # 部署文档
├── scripts/
│   ├── check_env.sh         # 新主机环境检查
│   ├── demo.sh              # 一键演示
│   └── monitor_resources.sh # 资源监控
├── Makefile
└── README.md
```

---

## 文档链接

- [实验结果报告](实验结果报告.md) — 全面性能测试数据
- [代码导读](代码导读.md) — 代码结构导读
- [汇报大纲](汇报大纲.md)
- [汇报材料](汇报材料.md)

---

## 技术平台

- GPU: RTX3060/4060/5060 (测试环境: Tesla V100-SXM2-32GB)
- CPU: x86_64 (测试环境) / 华为鲲鹏 920 (目标平台)
- 编程框架: CUDA SDK 12.8
- 文件系统: ext4

---

## 已知限制

| 限制 | 说明 |
|------|------|
| `MAP_SHARED` mmap | 共享写映射暂不支持 |
| `O_DIRECT` | 直接 I/O 未做特殊处理 |
| 单 GPU | 当前只使用 `cudaSetDevice(0)` |
| GPU 共享性能 | GPU 高负载时实时性能下降约 82%（458 vs 80 MB/s） |

---

## 参考资料

- [赛题说明](赛题说明.md)
- [NVIDIA nvCOMP](https://github.com/NVIDIA/CUDALibrarySamples/tree/master/nvCOMP)
- [ZFS Hardware Acceleration with QAT](https://openzfs.org/wiki/ZFS_Hardware_Acceleration_with_QAT)
- [XRP: In-Kernel Storage Functions with eBPF](https://github.com/xrp-project/XRP)

---

> 比赛截止时间：2026-06-29
> 参赛项目：2026年全国大学生计算机系统能力大赛-操作系统设计赛(全国)-OS功能挑战赛道
