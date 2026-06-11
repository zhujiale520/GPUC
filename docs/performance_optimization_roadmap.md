# GPUC 性能优化路线图（基于实验数据）

> 本文档基于 `实验结果报告.md` 中暴露的性能瓶颈，提出代码级的具体优化方案。
> 更新日期：2026-06-10

---

## 一、瓶颈分析与优化方案总览

| 优先级 | 瓶颈来源 | 实验证据 | 预期提升 | 代码改动量 | 状态 |
|--------|---------|---------|---------|-----------|------|
| 🔴 P0 | 单 CUDA Stream 并发竞争 | jobs=32 时 GPUC 从 3797 → 267 MB/s（4.9.5） | **10-15x**（恢复至 jobs=16 水平） | 中等 | ✅ 已实现，效果未达预期 |
| 🔴 P0 | CRC32 验证 CPU 开销 | 单线程占比 ~36%（258μs/709μs） | **1.5-2x**（跳过 CRC32） | 小 | ✅ 已实现，效果未达预期 |
| 🔴 P0 | mmap 全量预解压 | mmap 读取 7-12x 减速（4.9.7） | **5-10x**（接近 Baseline） | 较大 | ✅ 已实现，512MB 提升 10.4x |
| 🟡 P1 | GPU 计算负载抢占 | GPU-Util 100% 时降至 80 MB/s（8.2） | **2-5x**（恢复至 400+ MB/s） | 较小 | ✅ 已实现 |
| 🟡 P1 | 首次 I/O lazy init 延迟 | 首次 read 惩罚 ~200 ms（4.14） | 消除 200 ms 惩罚 | 较小 | ✅ 已实现 |
| 🟢 P2 | 小块随机读 IOPS 瓶颈 | 4k-128k IOPS 锁定 ~800（4.9.4） | **2-4x** IOPS 提升 | 中等 | ✅ 已实现 |
| 🟢 P2 | 写路径 header 开销 | Hook RAW 写入慢 13.5%（4.9.1） | **10-15%** 写入加速 | 较小 | ✅ 已实现 |

---

## 二、P0 — 高优先级优化

### 2.1 多 CUDA Stream 并行（解决 jobs=32 瓶颈）✅ 已实现

**问题根因**：
- 当前 `gpu_compress.cu` 中仅创建了 **2 个 CUDA Stream**（`g_streams[2]`），用于双缓冲流水线
- hook.c 中所有线程共享这 2 个 stream，通过 `cudaStreamSynchronize()` 等待完成
- jobs=32 时，32 个线程竞争 2 个 stream 的同步点，大量线程阻塞等待

**实验证据**：
- jobs=16：3797 MB/s（正常）
- jobs=32：267 MB/s（骤降 93%）

**优化实现（2026-06-10）**：

```c
// gpu_compress.cu
#define SGLZ_NUM_STREAMS 16
static cudaStream_t g_streams[SGLZ_NUM_STREAMS];
static void *g_d_batch_in[SGLZ_NUM_STREAMS];
static void *g_d_batch_out[SGLZ_NUM_STREAMS];
// ... 每个 stream 独立的 device 内存池（约 8.5 MB/stream）
```

```c
// hook.c — 按线程 TLS 分配 stream
#define MAX_TOTAL_STREAMS 16
static volatile int g_next_stream_base = 0;
static __thread int g_tls_stream_base = -1;

static int get_stream_id(int pipe_id) {
    if (g_tls_stream_base < 0) {
        g_tls_stream_base = __sync_fetch_and_add(&g_next_stream_base, 2) % MAX_TOTAL_STREAMS;
    }
    return (g_tls_stream_base + pipe_id) % MAX_TOTAL_STREAMS;
}
```

**实测效果**：
- 标准编译（含 CRC32）：jobs=32 时 **270.8 MB/s**（zero）、**269.1 MB/s**（rand）——**未达预期**
- 跳过 CRC32：单线程 O_DIRECT **363.8 MB/s**，较标准版 **350.6 MB/s** 仅提升 **3.8%**

**根因分析**：
- fio `sync` 引擎 + `numjobs=32` 模式下，32 个进程/线程的 I/O 请求无法有效合并为大批量 kernel 调用
- 每次 `read()` 只处理 1 个 128k block，kernel 启动开销（~30μs）占比极高，多 Stream 无法摊销
- 真正瓶颈是 **GPU kernel 启动延迟 + H2D/D2H 传输 + 单 batch 块数不足**，而非 stream 竞争

**结论**：多 Stream 优化代码已保留，作为高并发场景的基础设施。在 **bs≥1M** 或 **异步 I/O 深度≥16** 的场景下才能发挥价值。

### 2.2 CRC32 验证跳过（编译时可选）✅ 已实现

**问题根因**：
- Hook 内计时显示 `verify_batch_crc` 占单次 read 的 **36%**（258μs / 709μs）
- CRC32 查表法在该 CPU 上仅 **484 MB/s**

**优化实现**：
- `hook.c`：4 处 `verify_batch_crc` 调用包裹 `#ifndef GPUC_NO_VERIFY_CRC`
- 编译时通过 `make ABLATION_FLAGS="-DGPUC_NO_VERIFY_CRC"` 启用

**实测效果**：
- 单线程 O_DIRECT：标准版 **350.6 MB/s** → 跳过 CRC32 **363.8 MB/s**，提升 **3.8%**
- 多线程 jobs=32：标准版 **270.8 MB/s** → 跳过 CRC32 **268.6 MB/s**，**无提升**

**根因分析**：
- 端到端时间被 `cudaStreamSynchronize`（441μs，62%）主导，CPU 侧 CRC32 优化被 GPU 同步时间淹没
- 多线程场景下，各线程的 CRC32 计算可并行执行，进一步稀释了优化收益

**结论**：CRC32 跳过适合作为生产环境可选编译参数（牺牲数据完整性换取极限性能），但单独使用无法解决 jobs=32 骤降问题。

---

### 2.3 mmap 按需解压（解决 7-12x 减速）✅ 已实现

**问题根因**：
- 当前 `mmap()` 拦截实现：一次性调用 `read_compressed_at()` 预解压**整个文件**到匿名内存
- 512MB 文件需要解压 4096 个 block，耗时 ~2.4s（4.9.7）
- 数据库等按页映射场景每次只访问几 MB，但被迫等待全量解压

**实验证据**：
- 64MB 文件：421 ms（Baseline 58 ms，减速 7x）
- 512MB 文件：2415 ms（Baseline 264 ms，减速 12x）

**优化实现（2026-06-11）—— 方案 A**：

```c
// hook.c — mmap 拦截
#define MMAP_PRELOAD_MB 16   // 预解压前 16 MB

void *mmap(...) {
    // ... 原有逻辑 ...
    
    // 1. 小文件：同步全量解压
    if (length <= MMAP_PRELOAD_SIZE) {
        read_compressed_at(fd, info, buf, length, offset);
    } else {
        // 2. 大文件：同步解压前 16 MB
        read_compressed_at(fd, info, buf, MMAP_PRELOAD_SIZE, offset);
        
        // 3. 后台线程异步解压剩余部分
        int dup_fd = dup(fd);
        mmap_bg_ctx_t *ctx = calloc(1, sizeof(*ctx));
        ctx->fd = dup_fd;
        ctx->buf = buf;
        ctx->preload_len = MMAP_PRELOAD_SIZE;
        ctx->total_len = length;
        ctx->offset = offset;
        ctx->final_prot = prot;
        pthread_create(&ctx->thread, NULL, mmap_background_decompress, ctx);
    }
    return buf;
}
```

**后台线程**：`dup(fd)` + 重新 `read_header()` 获取独立的 block 表，调用 `read_compressed_at()` 解压剩余部分。完成后若 `final_prot != PROT_READ|PROT_WRITE`，则对剩余部分执行 `mprotect()`。

**`munmap()` / `msync()` 处理**：遍历 `g_mmap_table` 找到对应映射，若后台线程未结束则 `pthread_join` 等待，然后释放资源。

**实测效果**：

| 文件大小 | 优化前 mmap (ms) | 优化后 mmap (ms) | 提升倍数 |
|---------|-----------------|-----------------|---------|
| 64 MB | 420.9 | **226.3** | **1.9x** |
| 256 MB | 1263.3 | **229.8** | **5.5x** |
| 512 MB | 2414.5 | **231.4** | **10.4x** |
| 1 GB | 4688.6 | ~235 (预估) | **~20x** |

- 512MB 文件 `mmap()` 返回时间从 **2414 ms → 231 ms**，**提升 10.4x**
- 后台线程解压剩余 496MB 耗时约 **2.2s**，但不再阻塞 `mmap()` 返回

**遗留优化**：`userfaultfd` 方案（Linux 4.3+）可实现真正的按需页级解压，改动更大但效果更优。

---

## 三、P1 — 中优先级优化

### 3.1 高优先级 CUDA Stream + 负载自动 fallback（解决 GPU 负载抢占）✅ 已实现

**问题根因**：
- GPU-Util 100% 时，其他 CUDA 任务抢占了解压 kernel 的执行时间
- 当前 stream 使用默认优先级（0）

**实验证据**：
- GPU 空闲：458 MB/s
- GPU-Util 100%（1.4 GB 显存）：80 MB/s（下降 82%）

**优化实现（2026-06-11）**：

1. **高优先级 Stream**：`gpu_compress.cu` 中 `sglz_init()` 使用 `cudaStreamCreateWithPriority(&g_streams[s], cudaStreamDefault, greatestPriority)` 创建最高优先级 stream，减少被其他 CUDA 任务抢占的概率。

2. **GPU 负载检测**：`hook.c` 中 `should_cpu_fallback()` 每秒通过 `nvidia-smi` 检测 GPU 利用率，>80% 时返回 true。

3. **自动 fallback**：`read_compressed()` 和 `read_compressed_at()` 中，通过局部函数指针 `decomp_async`/`decomp_wait` 动态选择后端：
   - GPU 空闲时使用 GPU 后端（`g_backend_*`）
   - GPU 高负载时使用 CPU 后端（`cpu_decompress_batch_compact_async/wait`）

**预期效果**：
- 高优先级 stream：GPU-Util 100% 时带宽有望从 80 恢复至 **200-300 MB/s**
- 自动 fallback：极端负载下稳定保持 CPU 后端 177 MB/s

**工作量**：约 2 小时

---

### 3.2 后台预初始化线程（解决首次 I/O 200ms 惩罚）✅ 已实现

**问题根因**：
- `cudaSetDevice()` + `cudaStreamCreate()` + `cudaMalloc()`（~6 MB 显存池）累计约 200 ms
- 当前 lazy init 在第一次 I/O 时执行，阻塞 read() 返回

**实验证据**：
- GPU 路径首次 read：~200 ms
- CPU 路径首次 read：~30-55 ms

**优化实现（2026-06-11）**：

```c
// hook.c — constructor 中启动后台预初始化线程
static volatile int g_preinit_done = 0;

static void *preinit_thread(void *arg) {
    (void)arg;
    struct timespec ts = {0, 100000000};  // 延迟 100ms，避免 CUDA 驱动未就绪
    nanosleep(&ts, NULL);
    if (gpu_compress_init() == 0) {
        g_backend_initialized = 1;
    } else {
        gpu_compress_fini();  // 清理部分资源，让前台线程重试
    }
    g_preinit_done = 1;
    return NULL;
}
```

`hook_init()` 中选择 GPU 后端后，调用 `spawn_preinit_thread()` 启动后台线程。长生命周期应用首次 I/O 到来时，CUDA init 通常已完成，`ensure_backend_init()` 直接返回。

**预期效果**：
- 长生命周期应用（数据库、后台服务）：首次 I/O 降至 **<10 ms**（与 CPU 路径持平）
- 短生命周期命令（ls/cat）：后台线程可能尚未完成，仍由 `ensure_backend_init()` 处理

**工作量**：约 1.5 小时

---

## 四、P2 — 低优先级优化

### 4.1 LRU Block Cache（解决小块随机读 IOPS 瓶颈）✅ 已实现

**问题根因**：
- 4k 随机读仍需解压整个 128k block，然后裁剪
- IOPS 被锁定在 ~800，与 bs 大小无关

**优化实现（2026-06-11）**：

采用 **per-fd 单 block cache**（内存开销小，每个 fd 最多 128KB）：

```c
typedef struct {
    // ... 原有字段 ...
    uint32_t cache_block_id;
    uint8_t *cache_buf;
    int cache_valid;
} fd_info_t;
```

在 `read_compressed()` 和 `read_compressed_at()` 中：
1. 若只读取单个 block（`first_block == last_block`）且 cache 命中，直接 `memcpy` 返回
2. Batch 解压完成后，若单 block 读取，将解压结果拷贝到 `cache_buf`

`clear_fd_info()` 中释放 `cache_buf`。

**预期效果**：
- 随机读有局部性时（如数据库 B-tree 页）：IOPS 从 800 提升至 **2000-3000**
- 纯随机（无局部性）：无改善

**工作量**：约 2 小时

---

### 4.2 延迟 Header 写入（降低写路径开销）✅ 已实现

**问题根因**：
- `open()` 时立即写入 56 字节 RAW header，导致额外的磁盘 I/O
- Hook RAW 写入比 Baseline 慢 13.5%

**优化实现（2026-06-11）**：

```c
typedef struct {
    // ... 原有字段 ...
    int header_pending;
} fd_info_t;

static int flush_raw_header(int fd, fd_info_t *info) {
    if (!info->header_pending) return 0;
    ssize_t n = real_write(fd, &info->hdr, sizeof(info->hdr));
    if (n != sizeof(info->hdr)) return -1;
    info->header_pending = 0;
    return 0;
}
```

- `open()`：新文件标记 `header_pending = 1`，不立即写入 header
- `write()` / `pwrite64()` / `writev()`：首次写入时先 `flush_raw_header()`
- `close()`：若 `header_pending` 仍为 1，关闭前写入 header
- `lseek()` / `get_logical_size()`：`header_pending` 为 1 时物理偏移不加 header_size

**预期效果**：
- 只 open 不 write 的文件（如 `touch`）：零 header 开销
- 正常写入场景：减少一次磁盘 seek，写入带宽提升 **10-15%**

**工作量**：约 1 小时

---

## 五、未完成实验（从 experiment_optimization_plan.md 迁移）

> 以下实验尚未完成，评估完成后可增强报告说服力和评审竞争力。

### 5.1 元数据操作性能测试（stat/ls/find）

**背景**：Hook 拦截了 `__fxstat`/`__xstat`/`__lxstat`，每次需要 `open → read header → close`，大目录下影响显著。

**实验设计**：
```bash
# 创建 10000 个压缩文件
mkdir /tmp/metatest
for i in $(seq 1 10000); do
    LD_PRELOAD=./bin/libgpuhook.so dd if=/dev/zero of=/tmp/metatest/f$i bs=4K count=1 status=none
done
# 测试 ls -l 耗时，对比无 hook 基线
time ls -l /tmp/metatest | wc -l
```

**预期产出**：Hook 对 `ls`/`find`/`stat` 的延迟影响量化数据，展示 CPU fallback 的必要性。

### 5.2 海量小文件批量场景

**背景**：Inline 测试仅单文件延迟，缺少批量创建/读取/压缩全链路数据。

**实验设计**：
- 创建 10000 个 512B 小文件
- 测试 daemon 批量压缩耗时
- 测试批量 `cat` 读取耗时
- 对比：无 hook / Hook RAW / Hook INLINE

**预期产出**：10000 文件全链路性能对比表（创建/读取/压缩/空间占用）。

### 5.3 能耗效率对比（GPU vs CPU）

**背景**：GPU 功耗高于 CPU 但吞吐高，需验证 GPU 方案的 W/GB 效率是否占优。

**实验设计**：
```bash
nvidia-smi --query-gpu=power.draw --format=csv -l 1 > gpu_power.log &
# 运行解压任务，同步采样 CPU 功耗
```

**预期产出**：GPU vs CPU 解压的 GB/J 能效比值，若 GPU 更优则是大赛亮点。

### 5.4 与业界方案对比（ZFS/btrfs）

**背景**：缺少与成熟文件系统级压缩方案的量化对比。

**建议对比维度**：
| 方案 | 压缩率 | 顺序读带宽 | 侵入性 | 依赖 |
|------|--------|-----------|--------|------|
| GPUC (ours) | 6.3% | 458 MB/s | LD_PRELOAD | 用户态 |
| ZFS lz4 | ~6% | ~500 MB/s | 需格式化 | 内核态 |
| btrfs zstd | ~5% | ~450 MB/s | 需格式化 | 内核态 |

> 若环境装不了 ZFS/btrfs，可用文献数据。

### 5.5 实验复现指南（附录）

**内容**：在报告末尾增加环境准备、编译命令、复现各实验的脚本清单。

```markdown
## 附录 A：实验复现指南
### 编译
make clean && make all
### 复现 Table 4.9.2（顺序读性能）
bash tests/benchmark_fio.sh
### 复现 Ablation Study
make clean && make ABLATION_FLAGS="-DGPUC_NO_VERIFY_CRC" all
bash tests/benchmark_fio.sh
```

---
## 六、执行建议（2026-06-10 更新）

| 顺序 | 优化项 | 预计收益 | 工作量 | 状态 |
|------|--------|---------|--------|------|
| 1 | 多 CUDA Stream 并行 | **未达预期**（理论 10-15x，实际 ~1x） | 2h | ✅ 已实现 |
| 2 | CRC32 验证跳过 | **未达预期**（理论 1.5-2x，实际 1.04x） | 0.5h | ✅ 已实现 |
| 3 | mmap 预解压前 N MB | **达预期**（512MB 提升 10.4x） | 3h | ✅ 已实现 |
| 4 | 高优先级 Stream + 负载检测 | **已实现**（`cudaStreamCreateWithPriority` + `nvidia-smi` 检测 fallback） | 2h | ✅ 已实现 |
| 5 | 后台预初始化线程 | **已实现**（constructor 启动后台线程，延迟 100ms 后 CUDA init） | 1.5h | ✅ 已实现 |
| 6 | LRU Block Cache | **已实现**（per-fd 单 block cache，加速小块随机读） | 2h | ✅ 已实现 |
| 7 | 延迟 Header 写入 | **已实现**（open 时标记 pending，首次 write/close 时写入） | 1h | ✅ 已实现 |

> **核心结论**：
> - 多 CUDA Stream 和 CRC32 跳过均已实现，但**未解决 jobs=32 骤降问题**。根因是 fio sync 引擎 128k bs 下每次 read 仅处理 1 个 block，kernel 启动开销无法被多 Stream 摊销。
> - **mmap 按需解压已成功实现**，512MB 文件 `mmap()` 返回时间从 2414 ms 降至 231 ms，**提升 10.4x**。
> - **所有 roadmap 优化项（P0/P1/P2）已全部实现**。
>
> **下一步建议**：
> 1. 若需解决 jobs=32 性能：改用 **异步 I/O 引擎**（如 `io_uring` + 深度≥16）或 **bs≥1M**，使单次 read 覆盖多 block
> 2. 若需提升单线程极限：聚焦 **GPU kernel 启动延迟优化**（如 CUDA Graph）或 **更大 batch 合并**
> 3. 若需进一步提升 mmap 场景：实现 **userfaultfd** 按需页级解压
