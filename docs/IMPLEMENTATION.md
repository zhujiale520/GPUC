# GPUC 实现描述与代码说明

本文档从源码角度说明 GPUC 各核心模块的实现细节，帮助评审者和后续开发者理解代码结构、关键数据结构与算法流程。

---

## 1. 代码目录与模块划分

```
include/
├── file_header.h        # GPUC 文件格式、header 结构、CRC32
├── gpu_compress_api.h   # GPU/CPU/LZ4 后端统一 C API
└── lz4_minimal.h        # liblz4 最小函数声明

src/
├── hook.c               # LD_PRELOAD 拦截层（~2700 行，核心）
├── daemon.c             # GPU 离线压缩 Daemon
├── cpu_daemon.c         # CPU 离线压缩 Daemon（基准）
├── gpu_compress.cu      # SGLZ CUDA 压缩/解压实现
├── gpu_compress.cuh     # CUDA 内部常量与类型
├── cpu_compress.c       # SGLZ CPU 实现（对比基准）
├── gpu_lz4.cu           # nvCOMP LZ4 GPU 后端
├── cpu_lz4.c            # liblz4 CPU fallback
├── test_compress.c      # 单元/集成测试入口
├── test_cpu_vs_gpu.c    # CPU vs GPU 性能对比
├── test_hook.c          # Hook 行为测试
└── test_direct.c        # O_DIRECT 测试
```

---

## 2. GPUC 文件格式（`include/file_header.h`）

### 2.1 设计原则

- **自描述**：每个被管理文件头部附加固定大小 header，包含魔数、版本、状态、压缩算法、原始大小等信息；
- **固定块大小**：128 KB 分块，便于 GPU 并行处理；
- **向后兼容**：旧版 16 B block entry（无 CRC32）仍可通过 `header_size` 自动识别。

### 2.2 Header 结构

```c
struct gpuc_header {
    uint32_t magic;          // 0x47505543 "GPUC"
    uint32_t version;        // 当前为 1
    uint64_t orig_size;      // 原始逻辑大小
    uint32_t block_size;     // 固定 128KB
    uint32_t num_blocks;     // 总块数
    uint8_t  state;          // RAW / COMPRESSED / BUSY / INLINE
    uint8_t  comp_algo;      // NONE / SGLZ / LZ4 / Snappy
    uint16_t reserved;       // 对齐填充
    uint64_t header_size;    // 头 + 索引表总大小
    uint64_t mtime;          // 修改时间
    uint64_t ctime;          // 创建时间
};
```

实际 `sizeof(struct gpuc_header) = 56` 字节（`reserved` 到 `header_size` 之间有 4 字节编译器填充）。

### 2.3 Block Entry

```c
struct gpuc_block_entry {
    uint32_t orig_len;       // 原始长度（通常 128K，尾块可能不足）
    uint32_t comp_len;       // 压缩后长度
    uint64_t offset;         // 该块在文件中的物理偏移
    uint32_t crc32;          // 数据校验
    uint32_t reserved;       // 对齐预留
};
```

每个 entry 24 字节，向后兼容 16 字节旧版本：Hook 读取时根据 `header_size` 与 `num_blocks` 的比值判断 entry 大小。

### 2.4 文件状态机

| 状态 | 含义 | 转换条件 |
|---|---|---|
| `RAW` (0) | 原始数据，未压缩 | 新文件写入、fallback 保留 |
| `COMPRESSED` (1) | 已压缩为 GPUC 格式 | Daemon 完成压缩并 rename 后 |
| `BUSY` (2) | 正在被 Daemon 压缩 | 压缩过程中临时状态 |
| `INLINE` (3) | 小文件内联（≤1KB） | 数据直接跟在 56 B header 后，无 block entry |

### 2.5 小文件内联（INLINE）

对于 `data_size ≤ 1024 B` 的文件，不分配 block entry，直接将原始数据内联到 header 之后：

- `state = GPUC_STATE_INLINE`；
- `num_blocks = 0`；
- `header_size = sizeof(hdr) + data_size`。

这样避免小文件因 128 KB 对齐造成空间放大。

---

## 3. LD_PRELOAD 拦截层（`src/hook.c`）

`hook.c` 是系统最复杂的模块，约 2700 行，负责拦截 25+ 个 POSIX 系统调用，并维护每个 fd 的元数据。

### 3.1 核心数据结构

#### `fd_info_t`

每个被 hook 的 fd 对应一个 `fd_info_t`，记录文件状态、header、块索引表、单 block cache 等：

```c
typedef struct {
    int         fd;              // 原始 fd
    int         is_gpuc;         // 是否带有 GPUC header
    int         is_inline;       // 是否为 INLINE 小文件
    int         header_pending;  // header 延迟写入标记
    struct gpuc_header hdr;      // 文件头副本
    struct gpuc_block_entry *entries; // 块索引表
    off64_t     logical_size;    // 原始逻辑大小
    off64_t     phys_size;       // 物理文件大小
    off64_t     logical_offset;  // 当前文件逻辑偏移
    int         cache_block_id;  // per-fd 单 block cache
    uint8_t    *cache_buf;
    int         cache_valid;
    // ... 其他字段
} fd_info_t;
```

通过 `set_fd_info()` / `clear_fd_info()` / `get_fd_info()` 在全局 fd 表中管理。

#### 线程局部存储（TLS）

为避免多线程竞争，Hook 使用 TLS 分配：
- 单 stream 解压缓冲区；
- batch 解压输入/输出缓冲区；
- io_uring 相关结构。

TLS 缓冲区使用 `cudaHostAlloc` 分配 pinned memory，CUDA 拷贝时无需 driver 中转。

### 3.2 初始化与后端选择

#### `hook_init()`（constructor）

- 设置 `RTLD_NEXT` 函数指针；
- 初始化 fd 表、白名单、全局锁；
- 启动后台预初始化线程，延迟 100ms 后尝试 `gpu_compress_init()`；
- **不立即初始化 CUDA**，避免 constructor 阶段 CUDA 未就绪导致崩溃。

#### `ensure_backend_init()`（lazy init）

第一次 I/O 时触发：
1. 若后台预初始化已成功，直接返回；
2. 否则尝试 `gpu_compress_init()`；
3. 若失败，打印日志并 fallback 到 `cpu_compress_init()`；
4. 设置全局函数指针 `g_compress_*` / `g_decompress_*` 指向 GPU 或 CPU 实现。

#### `should_cpu_fallback()`

每秒通过 `nvidia-smi` 采样 GPU-Util，若 >80% 则返回 true，当前 read 路径使用 CPU 后端。

### 3.3 写路径

`write()` / `pwrite64()` / `writev()` 的处理流程：

1. 首次写入且 `header_pending` 时，调用 `flush_raw_header()` 写入 56 B RAW header；
2. 更新 fd 的 `logical_offset`；
3. 通过 `real_write()` 将用户数据写入物理文件（物理偏移 = header_size + 逻辑偏移）；
4. 不压缩，保证写路径低延迟。

**延迟 header 写入优化**：`open()` 时标记 `header_pending = 1`，不立即写 header；首次 `write()` 或 `close()` 时再写入。这减少了 `touch` 类操作和短生命周期命令的磁盘 I/O。

### 3.4 读路径（COMPRESSED 文件）

`read_compressed()` 的核心流程：

1. `ensure_backend_init()`；
2. 将用户请求的逻辑 offset 转换为 block_id；
3. 检查 per-fd single-block cache，命中则直接 `memcpy` 返回；
4. 未命中则进入 batch 解压路径：
   - 自适应 read-ahead：检测顺序/随机访问模式，顺序时预读窗口逐步扩展至 16 blocks；
   - 通过 io_uring 批量异步预读后续 block 的压缩数据；
   - 将紧凑格式数据一次性 H2D 拷贝到 GPU；
   - 启动 `sglz_decompress_compact_kernel` 同时解压最多 16×32=512 个 chunks；
   - `cudaStreamSynchronize()` 后 D2H 拷贝结果；
   - CRC32 校验（可通过 `-DGPUC_NO_VERIFY_CRC` 关闭）；
   - 拷贝请求范围到用户 buf。

#### 多 CUDA Stream

- `SGLZ_NUM_STREAMS = 16`；
- 每线程通过 TLS 分配 2 个 stream（pipe 0/1）用于双缓冲流水线；
- `get_stream_id()` 按线程 ID 分配 stream，减少线程间同步。

#### io_uring 集成

- 使用 Linux raw syscall 实现（`__NR_io_uring_setup` / `__NR_io_uring_enter`），不依赖 liburing；
- ring 深度默认 128，可通过 `GPUC_IOURING_DEPTH` 调节；
- 每次批量提交最多 16 个 block 的 `pread`；
- 失败时自动 fallback 到 `pread64`。

### 3.5 mmap 路径

`mmap()` 拦截实现：

1. 对 COMPRESSED/INLINE 文件的 `MAP_PRIVATE` 读映射，分配匿名内存；
2. 同步解压前 `MMAP_PRELOAD_SIZE`（默认 16 MB）；
3. 文件 > 16 MB 时启动后台 `pthread` 异步解压剩余部分；
4. 立即返回映射地址；
5. `munmap()` 时 `pthread_join` 等待后台解压完成；
6. `msync()` 对 `MAP_PRIVATE` 匿名映射直接返回成功。

限制：暂不支持 `MAP_SHARED` 写映射。

### 3.6 数据库文件白名单

`is_whitelisted_path()` 维护后缀白名单：`.db`、`.db-journal`、`.db-wal`、`.wal`、`.log`、`.ldb`、`.sst`、`CURRENT`、`MANIFEST-*`。

命中白名单的 fd：
- `open()` 直接返回原始 fd，不附加 GPUC header；
- 读/写按原始 offset 透传；
- `rename()` 临时文件到白名单目标时，若源为 RAW 状态，跳过 56 B header 复制真实内容。

### 3.7 stat / fstat 处理

拦截 `__fxstat` / `__xstat` / `__lxstat` 后，需要向上层报告**逻辑大小**而非物理稀疏大小。`adjust_stat_size()` 根据文件 header 将 `st_size` 替换为 `orig_size`。

---

## 4. 离线压缩 Daemon（`src/daemon.c`）

### 4.1 主流程

```
main()
├── 解析命令行参数（目录、递归、守护模式、扫描间隔）
├── 初始化 GPU/CPU 后端
├── 进入循环：
│   ├── scan_directory() 扫描目录
│   ├── 对每个 RAW 文件调用 compress_one_file()
│   └── 守护模式下 sleep 后再次扫描
└── 清理资源
```

### 4.2 文件扫描

`scan_directory()`：
- 递归遍历目录（若指定 `-r`）；
- 通过魔数判断文件是否为 GPUC RAW 文件；
- 维护 `processed_list` 避免单次运行重复处理；
- 尝试非阻塞 `flock` 获取独占锁，失败则跳过（避免与应用冲突）。

### 4.3 单文件压缩

`compress_one_file()`：

1. 打开原文件，读取 header；
2. 若文件为 INLINE 阈值内，转换为 INLINE 状态；
3. 否则按 128 KB 切分 block；
4. 调用 `sglz_compress_batch()` / `gpu_lz4_compress_batch()` 批量压缩；
5. 累积 `total_orig` 与 `total_comp`；
6. 写临时文件 `.gpuctmp`；
7. 计算整体压缩率：若高于 `GPUC_MIN_FILE_COMP_RATIO_PCT`（默认 85%），删除临时文件，保持 RAW；
8. 否则 `rename()` 原子替换原文件。

### 4.4 稀疏对齐

压缩后的 block 物理紧凑存放，但逻辑上仍占 128 KB。Daemon 通过 `lseek` 制造稀疏文件空洞，使文件逻辑大小保持不变，同时物理空间最小化。

### 4.5 CPU Daemon

`src/cpu_daemon.c` 提供纯 CPU 压缩 Daemon，结构与 GPU Daemon 类似，但调用 `cpu_compress_*` 系列函数。主要用于：
- 无 GPU 环境；
- GPU 后端对比基准。

---

## 5. SGLZ CUDA 实现（`src/gpu_compress.cu`）

### 5.1 算法概述

SGLZ（Simple GPU LZ）是本队自主实现的轻量级 LZ77 变体：

- 128 KB block = 32 × 4 KB chunks；
- 每个 chunk 独立压缩/解压；
- 3-byte 滚动 hash，256 槽位；
- 滑动窗口 2048 B；
- 最小匹配 4 B，最大匹配 255 B；
- 不可压缩 chunk 用 `0xFFFF` 标记，直接存储原始 4 KB。

### 5.2 CUDA Kernel

#### 压缩 Kernel

```c
__global__ void sglz_compress_chunks_kernel(const uint8_t *in_buf,
                                            uint8_t *out_buf,
                                            size_t chunk_size,
                                            int nchunks);
```

- 每个 CUDA block 处理一个 128 KB block；
- block 内 64 threads，每个 thread 处理一个 4 KB chunk；
- 将 hash 表从 local memory 迁移到 shared memory，采用 stride layout 避免 bank conflict。

#### 解压 Kernel

```c
__global__ void sglz_decompress_chunks_kernel(...);
__global__ void sglz_decompress_compact_kernel(...);
```

- `sglz_decompress_chunks_kernel`：输入为 slot 布局；
- `sglz_decompress_compact_kernel`：输入为磁盘紧凑格式，kernel 内通过 `chunk_offsets` 直接定位每个 chunk 数据，避免 CPU 侧 `memcpy`。

### 5.3 Batch API

```c
int sglz_compress_batch(int n, ...);
int sglz_decompress_batch(int n, ...);
int sglz_decompress_batch_compact(int n, ...);
int sglz_decompress_batch_compact_async(int n, ..., int stream_id);
int sglz_decompress_batch_compact_wait(int stream_id, int n, ...);
```

- `n` 为 block 数，最大 16（Hook）或 32（Daemon）；
- `_compact` 系列处理磁盘紧凑格式；
- `_async` / `_wait` 支持双缓冲流水线。

### 5.4 Device Memory Pool

`sglz_init()` 预分配：
- `g_d_batch_in`：输入缓冲区（16/32 × 32 × 4352 B）；
- `g_d_batch_out`：输出缓冲区（16/32 × 128 KB）；
- `g_d_batch_out_lens`：输出长度数组；
- 16 个 CUDA stream 各自的独立内存池。

运行时直接复用预分配内存，完全消除 `cudaMalloc/cudaFree`。

### 5.5 高优先级 Stream

`sglz_init()` 使用 `cudaStreamCreateWithPriority(..., greatestPriority)` 创建最高优先级 stream，减少 GPU 共享场景下被其他 CUDA 任务抢占。

---

## 6. nvCOMP LZ4 后端（`src/gpu_lz4.cu` / `src/cpu_lz4.c`）

### 6.1 GPU 后端

`src/gpu_lz4.cu` 封装 NVIDIA nvCOMP 4.2 的 Batched LZ4 API：

- 每个 128 KB block 作为一个独立 chunk；
- 输出格式：`[1B flag][payload]`，`flag=0` 表示未压缩存储，`flag=1` 表示 LZ4 payload；
- 提供与 SGLZ 同形态的 batch API，便于 Hook 和 Daemon 统一调用。

### 6.2 CPU Fallback

`src/cpu_lz4.c` 基于系统 liblz4 实现 CPU 解压路径：

- 解析 `[flag][payload]` 格式；
- flag=0 时直接 memcpy；
- flag=1 时调用 `LZ4_decompress_safe`；
- 保证 GPU 不可用时仍可读取 LZ4 格式文件。

---

## 7. CPU SGLZ 实现（`src/cpu_compress.c`）

`src/cpu_compress.c` 是 SGLZ 的纯 CPU 串行实现，算法与 `gpu_compress.cu` 完全一致，主要用于：

- GPU 不可用时作为 fallback；
- 作为 GPU offload 的对比基准。

实现上每个 chunk 由单个 CPU 线程串行处理，使用栈上 hash 表。batch API 将多个 chunk 依次调用单 chunk 函数。

---

## 8. 测试程序

### 8.1 `test_compress.c`

单元/集成测试入口，覆盖：
- GPU/CPU 单块压缩解压一致性；
- batch 压缩解压一致性；
- 紧凑格式解压；
- 随机数据 fallback；
- CRC32 校验。

### 8.2 `test_cpu_vs_gpu.c`

对比 CPU 串行压缩与 GPU batch 压缩吞吐：
- 输出压缩耗时、吞吐、加速比；
- 用于快速验证 GPU offload 收益。

### 8.3 `test_hook.c`

测试 Hook 行为：
- RAW 文件读写；
- 压缩文件透明读取；
- mmap 读取；
- CPU fallback 路径。

---

## 9. Makefile 与编译选项

### 9.1 主要目标

```bash
make all          # 编译所有目标
make bin/libgpuhook.so
make bin/gpu_compress_daemon
make bin/cpu_compress_daemon
make test         # 编译并运行单元/集成测试
```

### 9.2 自动 GPU 架构检测

Makefile 通过 `nvidia-smi` 自动检测 GPU 计算能力，默认使用 `-arch=sm_70`（V100）。可手动覆盖：

```bash
make GPU_ARCH=75
```

### 9.3 消融实验编译参数

```bash
make ABLATION_FLAGS="-DGPUC_NO_BATCH -DGPUC_NO_IOURING -DGPUC_NO_READAHEAD"
```

常用宏：
- `GPUC_NO_BATCH`：关闭 batch decompress，逐块处理；
- `GPUC_NO_IOURING`：关闭 io_uring，使用 `pread64`；
- `GPUC_NO_READAHEAD`：关闭自适应 read-ahead；
- `GPUC_NO_PINNED`：使用 `malloc` 代替 `cudaHostAlloc`；
- `GPUC_NO_VERIFY_CRC`：跳过 CRC32 校验；
- `GPUC_NO_PIPELINE`：关闭双缓冲流水线。

### 9.4 无 GPU 编译

```bash
make bin/libcpuhook.so bin/cpu_compress_daemon
```

仅编译 CPU 相关目标，无需 nvcc。

---

## 10. 代码阅读建议

| 关注点 | 推荐阅读顺序 |
|---|---|
| 文件格式 | `include/file_header.h` |
| 整体 API | `include/gpu_compress_api.h` |
| 压缩算法 | `src/gpu_compress.cu` 第 33-260 行 kernel 部分 |
| 读路径优化 | `src/hook.c` 中 `read_compressed()`、`ensure_batch_tls_buffers()`、`gpuc_iouring_*` |
| 写路径 | `src/hook.c` 中 `write()`、`flush_raw_header()` |
| mmap 实现 | `src/hook.c` 中 `mmap()`、`mmap_bg_decompress_thread()`、`munmap()` |
| Daemon | `src/daemon.c` 中 `compress_one_file()`、`scan_directory()` |
| 问题排查 | `docs/ISSUES_AND_SOLUTIONS.md` |
