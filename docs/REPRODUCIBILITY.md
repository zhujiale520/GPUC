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
make bin/libcpuhook.so bin/cpu_compress_daemon bin/test_compress
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

预期结果（512 MB zero 数据，128k bs，page cache 命中）：
- Baseline：~450 MB/s
- Hook RAW：~451 MB/s
- GPU Compressed：**~458 MB/s**

### 4.2 随机读性能

```bash
bash tests/random_read_small_bs.sh
```

预期结果（GPU Compressed，zero 数据）：
- IOPS 在 4k–128k bs 范围内稳定在 **~800**；
- 平均延迟约 **1.2 ms**。

### 4.3 jobs=32 高并发

```bash
bash tests/benchmark_high_concurrency.sh
```

预期结果（direct=1）：
- zero 128k：GPUC 达到 Baseline 的 **99.8%**；
- zero 1M：GPUC 达到 Baseline 的 **99.7%**。

### 4.4 mmap 按需解压

```bash
bash tests/mmap_size_sweep.sh
```

预期结果：
- 512 MB 文件 `mmap()` 返回时间约 **231 ms**；
- 优化前为 2414 ms，提升 **10.4x**。

### 4.5 压缩率

```bash
bash tests/compressibility_gradient.sh
```

预期结果（512 MB 文件）：

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
    sha256sum /tmp/gpuc_test/headers.tar
```

预期结果（Linux headers，~35 MB）：
- SGLZ 压缩率：~82.5%
- LZ4 压缩率：**~38.6%**
- LZ4 128k 顺序读带宽：**~581 MB/s**

### 4.7 真实 Workload

```bash
bash tests/real_workload_comprehensive.sh
bash tests/db_whitelist.sh
```

预期结果：
- SQLite 建表/插入/SELECT：**PASS**
- LevelDB fillseq/readseq/readrandom：**PASS**
- ccache cold/hot compile：Hook 引入 14–26% overhead

### 4.8 消融实验

```bash
bash tests/ablation_study.sh
```

预期结果（512 MB zero，128k bs，page cache 命中）：

| 实验组 | 关闭的优化 | 顺序读带宽 |
|---|---|---|
| 全优化基线 | 无 | ~147.9 MB/s |
| 关闭 io_uring | `-DGPUC_NO_IOURING` | ~135.1 MB/s |
| 关闭 Read-Ahead | `-DGPUC_NO_READAHEAD` | ~122.1 MB/s |
| 关闭 Batch | `-DGPUC_NO_BATCH` | ~123.1 MB/s |

### 4.9 容错与边界

```bash
bash tests/fault_tolerance_boundary.sh
```

预期结果：
- Daemon 压缩时应用并发读/写：**PASS**
- GPU 显存不足 fallback：**PASS**
- 磁盘空间不足：**PASS**
- 进程崩溃一致性：**PASS**
- fsync 语义：**PASS**

### 4.10 生产级指标

```bash
bash tests/production_metrics.sh
```

预期结果（512 MB zero，randread 128k）：
- p99 读延迟：**~457 µs**
- p999 读延迟：**~578 µs**
- IOPS：**~3355**

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

若 GPU 不可用，系统会自动 fallback 到 CPU 后端，Hook 仍可工作。

### 6.3 压缩率异常

- 随机数据无法压缩，会保持 RAW 状态；
- 使用 `./bin/test_compress` 验证算法正确性。

### 6.4 fio 崩溃

```bash
# 临时禁用 Hook 定位问题
LD_PRELOAD=./bin/libgpuhook.so GPUC_NO_HOOK=1 fio ...
```

### 6.5 空间不足

Daemon 压缩过程中需要临时文件 `.gpuctmp`，确保目标目录有足够空间。

---

## 7. 一键完整验证

```bash
# 环境检查
bash scripts/check_env.sh

# 编译
make clean && make all

# 运行所有测试
make test

# 一键 DEMO
bash scripts/demo.sh
```

若以上命令全部通过，说明环境配置正确，核心功能可复现。
