# GPUC 实验复现指南

本文档说明如何在本地环境复现 GPUC 项目的核心实验。所有命令均以项目根目录为工作目录。

---

## 1. 环境要求

### 1.1 硬件

- NVIDIA GPU（计算能力 ≥ 7.0）
  - 测试平台：Tesla V100-SXM2-32GB
  - 兼容：RTX 3060/4060/5060、A100、H100 等
- x86_64 服务器
- 推荐 NVMe SSD，以便发挥压缩后 I/O 优势

### 1.2 软件

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y build-essential g++ gcc
sudo apt-get install -y nvidia-driver-xxx nvidia-cuda-toolkit
sudo apt-get install -y fio python3 bc xxd linux-headers-$(uname -r)
```

验证：

```bash
nvcc --version
nvidia-smi
```

### 1.3 环境检查脚本

```bash
bash scripts/check_env.sh
```

输出示例：

```
--- GPU / CUDA 检测 ---
[PASS] NVIDIA GPU detected: Tesla V100-SXM2-32GB, 7.0
[INFO] Makefile will use: -arch=sm_70
[PASS] nvcc: 12.8, V12.8.61
...
环境检查全部通过，可以执行 'make all && make test'
```

---

## 2. 编译

首次构建先准备仓库内依赖：

```bash
bash scripts/setup_dependencies.sh
```

### 2.1 完整编译（GPU + CPU）

```bash
make clean
make all
```

产物：

| 文件 | 说明 |
|---|---|
| `bin/libgpuhook.so` | LD_PRELOAD 拦截层 |
| `bin/gpu_compress_daemon` | GPU 离线压缩 Daemon |
| `bin/cpu_compress_daemon` | CPU 离线压缩 Daemon |
| `bin/test_compress` | 单元/集成测试 |
| `bin/test_cpu_vs_gpu` | CPU vs GPU 性能对比 |
| `bin/test_hook` | Hook 行为测试 |

### 2.2 仅 CPU 编译（无 GPU 环境）

```bash
make clean
make cpu-only
```

### 2.3 消融实验编译

```bash
make clean
make all ABLATION_FLAGS="-DGPUC_NO_BATCH -DGPUC_NO_IOURING -DGPUC_NO_READAHEAD"
```

常用消融宏：
- `-DGPUC_NO_BATCH`：逐块解压
- `-DGPUC_NO_IOURING`：禁用 io_uring
- `-DGPUC_NO_READAHEAD`：禁用自适应 read-ahead
- `-DGPUC_NO_PINNED`：禁用 pinned memory
- `-DGPUC_NO_VERIFY_CRC`：跳过 CRC32 校验

---

## 3. 基础使用流程

### 3.1 单文件写入 → 压缩 → 读取

```bash
# 1. 创建测试目录
mkdir -p /tmp/gpuc_test

# 2. 通过 Hook 写入 RAW 文件（自动附加 56 B header）
LD_PRELOAD=./bin/libgpuhook.so GPUCOMPRESS_QUIET=1 \
    dd if=/dev/zero of=/tmp/gpuc_test/file.bin bs=1M count=512 status=none

# 3. GPU 后台压缩
./bin/gpu_compress_daemon /tmp/gpuc_test

# 4. 透明读取压缩文件
LD_PRELOAD=./bin/libgpuhook.so GPUCOMPRESS_QUIET=1 \
    dd if=/tmp/gpuc_test/file.bin of=/dev/null bs=1M status=none
```

### 3.2 查看文件状态

```bash
# 查看 header
xxd -l 64 /tmp/gpuc_test/file.bin

# 查看物理大小 vs 逻辑大小
ls -l /tmp/gpuc_test/file.bin          # 逻辑大小
 du -B1 /tmp/gpuc_test/file.bin        # 物理块占用
```

---

## 4. 核心实验复现

### 4.1 顺序读性能

```bash
bash tests/benchmark_fio.sh
```

该脚本会测试 Baseline、Hook RAW、CPU Compressed、GPU Compressed 四种状态的顺序读。

脚本输出仅用于当前机器的复测结果，不应把其他环境的历史数值作为“预期值”。
报告结果时同时保留原始输出、缓存条件和输入文件校验和。

### 4.2 随机读性能

```bash
bash tests/random_read_small_bs.sh
```

报告 IOPS、平均延迟和尾延迟时必须注明数据类型、缓存条件、fio 引擎和并发数。

### 4.3 jobs=32 高并发

```bash
bash tests/benchmark_high_concurrency.sh
```

该脚本为 Baseline、Hook RAW 和 GPU Compressed 创建内容相同但互相独立的文件，
并记录 header 状态、逻辑校验和、表观大小和物理占用。默认重复 5 次并输出
mean/std/95% CI。GPU Compressed 的“有效逻辑带宽”可能因减少物理 I/O 而高于
dense Baseline，不能解释为纯解压吞吐。

### 4.4 mmap userfaultfd 缺页填充

```bash
GPUC_MMAP_MODE=userfaultfd GPUC_MMAP_SIZES="64M 256M" \
GPUC_MMAP_THREADS=1 GPUC_REPEATS=5 bash tests/mmap_size_sweep.sh
```

测试使用逐页不同的非零 pattern，先随机访问一页，再并发扫描全部页；CSV 分开
记录 `mmap_ms`、`first_fault_us` 和 `scan_ms`。handler 以 128 KiB GPUC block
填充，并非每 fault 只解压一个 4 KiB 页。

可用模式：

```bash
GPUC_MMAP_MODE=sync bash tests/mmap_size_sweep.sh       # 强制同步回退
GPUC_MMAP_MODE=userfaultfd bash tests/mmap_size_sweep.sh # UFFD 不可用则失败
GPUC_MMAP_THREADS=8 bash tests/mmap_size_sweep.sh       # 并发页扫描
```

### 4.5 压缩率

```bash
bash tests/compressibility_gradient.sh
```

历史参考值（尚未按本轮统一方法复测，不作为决赛结论）：

| 可压缩率 | 压缩率 | 解压读带宽 |
|---------|--------|-----------|
| 0% | 100.0% | ~296 MB/s |
| 25% | 78.1% | ~224 MB/s |
| 50% | 53.1% | ~268 MB/s |
| 75% | 28.2% | ~337 MB/s |
| 100% | 3.2% | ~546 MB/s |

### 4.6 nvCOMP LZ4 后端

需要本地准备 nvCOMP 库（`third_party/nvcomp`）和 liblz4 符号链接（`third_party/lz4/liblz4.so`）。

```bash
# 写入文本类数据
LD_PRELOAD=./bin/libgpuhook.so GPUCOMPRESS_QUIET=1 \
    tar cf /tmp/gpuc_test/headers.tar /usr/include

# 使用 LZ4 后端压缩
GPUC_ALGO=lz4 ./bin/gpu_compress_daemon /tmp/gpuc_test

# 透明读取
LD_PRELOAD=./bin/libgpuhook.so GPUCOMPRESS_QUIET=1 \
    dd if=/tmp/gpuc_test/headers.tar status=none | sha256sum
```

说明：部分 coreutils 可能绕过被拦截的 libc `read()`；复测逻辑内容时使用上面的
`dd | sha256sum`，并将结果与压缩前输入校验和比较。

2026-07-29 正式五轮结果（固定 `/usr/include` tar，37,703,680 B）：

- SGLZ allocated ratio：81.8%，warm read 107.8 ± 0.3 MiB/s；
- LZ4 allocated ratio：38.1%，warm read 81.0 ± 0.1 MiB/s；
- 原始 JSON/CSV：`results/final/backends_v100_20260729/`。

### 4.7 真实 Workload

```bash
bash tests/real_workload_comprehensive.sh
bash tests/db_whitelist.sh
```

这些脚本是历史 workload 探索，不满足本轮“公开来源/版本/SHA-256 + 五次重复 +
cold/warm 分离”的核心结果标准。运行成功只能说明该次兼容性，不得直接写入决赛
性能结论。当前 PPT 和实验报告已移除旧 SQLite/LevelDB/ccache 性能数字。

### 4.8 消融实验

```bash
bash tests/ablation_study.sh
```

2026-07-29 正式结果：

| 实验组 | 关闭的优化 | 顺序读带宽 |
|---|---|---|
| 全优化基线 | 无 | 182.0 MiB/s |
| 关闭 io_uring | `-DGPUC_NO_IOURING` | 182.4 MiB/s |
| 关闭 Read-Ahead | `-DGPUC_NO_READAHEAD` | 161.8 MiB/s |
| 关闭 Batch | `-DGPUC_NO_BATCH` | 162.0 MiB/s |
| 关闭 pinned memory | `-DGPUC_NO_PINNED` | 177.3 MiB/s |

### 4.9 容错与边界

核心边界使用可重复、无需 root 的脚本：

```bash
make smoke-test
bash tests/test_concurrent_daemon.sh
bash tests/fault_recovery.sh
```

它们覆盖 POSIX RAW 语义、COMPRESSED `EROFS`、白名单原子 rename、损坏格式、
2000 个 fuzz case、同路径非 flock reader 在 daemon 原子替换期间的一致性，以及
确定性 Daemon ENOSPC、SIGKILL、残留临时文件重启、GPU 不可见 CPU fallback 和
`/dev/full`。真实 GPU reset/主机断电需要隔离且有管理员权限的机器，不作为本机
自动 PASS 结论。

### 4.10 长稳与代码覆盖率

```bash
# 默认 1 小时；短 smoke 可设置 GPUC_RUNTIME=10
GPUC_RESULT_DIR=results/local/stability \
GPUC_RUNTIME=3600 GPUC_SIZE=256M bash tests/long_term_stability.sh

# GCC 自带 gcov，无需 lcov
GPUC_RESULT_DIR=results/local/coverage bash tests/coverage_cpu.sh
# 或使用 CI 同款目标
make coverage-test
```

长稳脚本保存 fio JSON、一秒带宽日志、500 ms GPU 指标和运行前后逻辑 SHA。
覆盖率脚本覆盖 CPU Hook、CPU Daemon、SGLZ/LZ4 CPU helper，并要求
`src/hook.c` 行覆盖率不低于 35%。它不代表 CUDA kernel 行覆盖率。

### 4.11 工程指标探索

```bash
bash tests/production_metrics.sh
```

该脚本输出单机工程观测值。一次测试不能证明“生产级”，必须保留 fio JSON、
环境信息、重复次数和置信区间，并在不同硬件与真实工作负载上复测。

### 4.12 同吞吐 CPU/GPU 卸载

```bash
GPUC_RUNTIME=5 GPUC_REPEATS=5 GPUC_BUSINESS_WORKERS=4 \
GPUC_TARGET_MIB_S=4096 GPUC_DECOMP_CPU=0 GPUC_WORKER_CPU=0 \
bash tests/cpu_offload_business.sh
```

CPU 与 GPU 使用相同的 CPU-generated LZ4 blocks，并限制到同一解压吞吐。
`GPUC_DECOMP_CPU` 和 `GPUC_WORKER_CPU` 必须显式记录，避免 GPU worker 偷用空闲
核心造成不公平结果。输出包含业务吞吐、进程/submit/worker CPU、RSS、fault、
context switch、GPU 利用率/功耗和各 pipeline 阶段。

### 4.12 SQLite 并行业务

```bash
GPUC_RUNTIME=5 GPUC_REPEATS=5 GPUC_BUSINESS_WORKERS=4 \
GPUC_SQLITE_ROWS=100000 GPUC_SQLITE_SPAN=1024 \
GPUC_TARGET_MIB_S=4096 GPUC_DECOMP_CPU=0 GPUC_WORKER_CPU=0 \
bash tests/sqlite_offload_business.sh
```

脚本生成确定性的 SQLite 数据库，执行 indexed range aggregate，并随机轮转
baseline/CPU/GPU 场景，报告 QPS、p50/p95/p99 和并行解压资源指标。

### 4.13 对齐压缩格式与 O_DIRECT

```bash
GPUC_SIZE=512M GPUC_RUNTIME=15 \
GPUC_RESULT_DIR=results/local/odirect \
bash tests/odirect_read.sh
```

脚本同时验证 header flag/4 KiB 对齐、`F_GETFL` 仍保留 `O_DIRECT`、逻辑内容与
fio error。报告时必须引用 `environment.txt` 中的实际 source/filesystem；在
SATA 上运行不能写成 NVMe 成绩。

### 4.14 fio 压缩多线程退出回归

```bash
GPUC_SIZE=64M GPUC_RUNTIME=3 GPUC_REPEATS=5 \
GPUC_BS_LIST="4k 16k 128k" GPUC_THREAD_LIST="1 4" \
GPUC_SAMPLE_TIMEOUT=35 \
bash tests/fio_compressed_thread_regression.sh
```

脚本生成逐页不同的非零可压缩 pattern，分别构造 SGLZ 与 LZ4 COMPRESSED
文件。每个组合使用 fio sync engine 和 thread mode，保存逐轮 JSON、fio
runtime、进程墙钟时间、吞吐和逻辑 SHA-256；任何 timeout、fio error 或校验
不一致都会立即失败。2026-07-30 V100 正式结果为 60/60 通过，见
`results/final/fio_compressed_threads_v100_20260730/`。

---

## 5. 关键环境变量

| 环境变量 | 说明 | 默认值 |
|---|---|---|
| `LD_PRELOAD` | 加载 Hook 共享库 | `./bin/libgpuhook.so` |
| `GPUC_ALGO` | 压缩后端：`sglz` 或 `lz4` | `sglz` |
| `GPUC_QUIET` / `GPUCOMPRESS_QUIET` | 抑制 Hook 输出 | `0` |
| `GPUC_IOURING_DEPTH` | io_uring ring 深度 | `128` |
| `GPUC_MIN_FILE_COMP_RATIO_PCT` | 文件级 fallback 压缩率阈值 | `85` |
| `GPUC_NO_DB_WHITELIST` | 关闭数据库白名单 | `0` |
| `GPUC_WHITELIST` | 追加自定义后缀白名单 | 空 |
| `GPUC_NO_HOOK` | 保留 Hook 加载但禁用拦截 | `0` |
| `GPUC_ENABLE_NVIDIA_SMI_FALLBACK` | 允许低频调用 `nvidia-smi` 做负载 fallback 探索；默认关闭，避免读路径创建进程 | `0` |
| `GPUC_WORKER_CPU` | 固定长期 LZ4 GPU worker 的 CPU affinity | 不固定 |
| `GPUC_CUDA_SPIN_WAIT` | `1` 使用 CUDA busy-spin；默认 blocking sync 节省主机 CPU | `0` |

---

## 6. 常见问题排查

### 6.1 Hook 不生效

- 确认 `LD_PRELOAD` 路径为绝对路径或相对当前目录的正确路径；
- 确认应用是动态链接的（`ldd ./app`）；
- 静态编译的程序无法被 LD_PRELOAD 拦截。

### 6.2 GPU 初始化失败

```bash
nvidia-smi
nvcc --version
```

GPU Hook 需要可用的 CUDA 设备。CPU 路径请显式使用 `bin/libcpuhook.so` 和
`bin/cpu_compress_daemon`。基于 `nvidia-smi` 的负载检测仅在显式设置
`GPUC_ENABLE_NVIDIA_SMI_FALLBACK=1` 时启用，不属于默认热路径。

### 6.3 压缩率异常

- 随机数据无法压缩，会保持 RAW 状态；
- 使用 `./bin/test_compress` 验证算法正确性。

### 6.4 fio 崩溃

```bash
# 临时禁用 Hook 定位问题
LD_PRELOAD=./bin/libgpuhook.so GPUC_NO_HOOK=1 fio ...
```

如果 fio 已完成 runtime 但多线程进程不退出，优先检查是否在 fd 表锁内调用
CUDA、分配器或其他可能阻塞的资源释放函数。当前实现要求 fd 表锁只保护表项和
引用计数，CUDA 页锁定内存必须在解锁后释放。可运行 4.14 的专项脚本复核。

### 6.5 空间不足

Daemon 压缩过程中需要同目录临时文件 `.gpuc_tmp`，确保目标目录有足够空间。

---

## 7. 一键完整验证

```bash
# 环境检查
bash scripts/check_env.sh

# 编译
bash scripts/setup_dependencies.sh
make clean && make all

# 运行所有测试
make test

# 一键 DEMO
bash scripts/demo.sh
```

若以上命令全部通过，说明环境配置正确，核心功能可复现。
