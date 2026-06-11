# GPUC 性能优化路线图（基于实验数据）

> 本文档基于 `实验结果报告.md` 中暴露的性能瓶颈，提出代码级的具体优化方案。
> 更新日期：2026-06-10

---

## 一、瓶颈分析与优化方案总览

| 优先级 | 瓶颈来源 | 实验证据 | 预期提升 | 代码改动量 | 状态 |
|--------|---------|---------|---------|-----------|------|
| 🔴 P0 | 单 CUDA Stream 并发竞争 | jobs=32 时 GPUC 从 3797 → 267 MB/s（4.9.5） | **10-15x**（恢复至 jobs=16 水平） | 中等 | ✅ 已实现，效果未达预期 |
| 🔴 P0 | CRC32 验证 CPU 开销 | 单线程占比 ~36%（258μs/709μs） | **1.5-2x**（跳过 CRC32） | 小 | ✅ 已实现，效果未达预期 |
| 🔴 P0 | mmap 全量预解压 | mmap 读取 7-12x 减速（4.9.7） | **5-10x**（接近 Baseline） | 较大 | 待实现 |
| 🟡 P1 | GPU 计算负载抢占 | GPU-Util 100% 时降至 80 MB/s（7.2） | **2-5x**（恢复至 400+ MB/s） | 较小 | 待实现 |
| 🟡 P1 | 首次 I/O lazy init 延迟 | 首次 read 惩罚 ~200 ms（4.14） | 消除 200 ms 惩罚 | 较小 | 待实现 |
| 🟢 P2 | 小块随机读 IOPS 瓶颈 | 4k-128k IOPS 锁定 ~800（4.9.4） | **2-4x** IOPS 提升 | 中等 | 待实现 |
| 🟢 P2 | 写路径 header 开销 | Hook RAW 写入慢 13.5%（4.9.1） | **10-15%** 写入加速 | 较小 | 待实现 |

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

### 2.3 mmap 按需解压（解决 7-12x 减速）

**问题根因**：
- 当前 `mmap()` 拦截实现：一次性调用 `read_compressed_at()` 预解压**整个文件**到匿名内存
- 512MB 文件需要解压 4096 个 block，耗时 ~2.4s（4.9.7）
- 数据库等按页映射场景每次只访问几 MB，但被迫等待全量解压

**实验证据**：
- 64MB 文件：421 ms（Baseline 58 ms，减速 7x）
- 512MB 文件：2415 ms（Baseline 264 ms，减速 12x）

**优化方案 A：预解压前 N MB + 后台异步解压（推荐，改动最小）**

```c
// hook.c — mmap 拦截
#define MMAP_PRELOAD_MB 16   // 预解压前 16 MB

void *mmap(...) {
    // ... 原有逻辑 ...
    
    // 1. 只预解压前 MMAP_PRELOAD_MB
    size_t preload_len = (length < MMAP_PRELOAD_MB * 1024 * 1024) 
                         ? length : MMAP_PRELOAD_MB * 1024 * 1024;
    ssize_t nread = read_compressed_at(fd, info, buf, preload_len, offset);
    
    // 2. 后台线程异步解压剩余部分
    if (length > preload_len) {
        pthread_t bg;
        mmap_bg_ctx *ctx = malloc(sizeof(*ctx));
        ctx->fd = fd; ctx->info = info; ctx->buf = buf;
        ctx->offset = offset + preload_len;
        ctx->length = length - preload_len;
        pthread_create(&bg, NULL, mmap_background_decompress, ctx);
        pthread_detach(bg);
    }
    return buf;
}
```

**优化方案 B：userfaultfd 按需解压（Linux 4.3+，效果最优但改动大）**

```c
// 注册 userfaultfd，在 page fault 时解压对应 block
int uffd = syscall(__NR_userfaultfd, O_CLOEXEC | O_NONBLOCK);
// 按 128k block 粒度映射，page fault 时调用 read_compressed_at() 解压单个 block
```

**预期效果**：
- 方案 A：按页映射场景（每次几 MB）延迟从 2.4s 降至 **~150 ms**，接近 Baseline
- 方案 B：理论上可达到 Baseline 级别（无预解压开销）

**工作量**：
- 方案 A：约 3 小时
- 方案 B：约 1 天

---

## 三、P1 — 中优先级优化

### 3.1 高优先级 CUDA Stream（解决 GPU 负载抢占）

**问题根因**：
- GPU-Util 100% 时，其他 CUDA 任务抢占了解压 kernel 的执行时间
- 当前 stream 使用默认优先级（0）

**实验证据**：
- GPU 空闲：458 MB/s
- GPU-Util 100%（1.4 GB 显存）：80 MB/s（下降 82%）

**优化方案**：

```c
// gpu_compress.cu
int leastPriority, greatestPriority;
cudaDeviceGetStreamPriorityRange(&leastPriority, &greatestPriority);

// 创建高优先级 stream（数值越小优先级越高）
cudaStreamCreateWithPriority(&g_streams[s], cudaStreamDefault, greatestPriority);
```

**配合策略**：实时 GPU 负载检测 + 自动 fallback

```c
// hook.c — 检测 GPU 利用率
static int gpu_utilization_high(void) {
    static time_t last_check = 0;
    static int last_util = 0;
    time_t now = time(NULL);
    if (now - last_check > 1) {  // 每秒检测一次
        FILE *f = popen("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits", "r");
        if (f) { fscanf(f, "%d", &last_util); pclose(f); }
        last_check = now;
    }
    return last_util > 80;  // >80% 认为高负载
}

// 在 read_compressed_at() 开头：
if (gpu_utilization_high()) {
    // 自动 fallback 到 CPU 后端
    return cpu_decompress_path(...);
}
```

**预期效果**：
- 高优先级 stream：GPU-Util 100% 时带宽有望从 80 恢复至 **200-300 MB/s**
- 自动 fallback：极端负载下稳定保持 CPU 后端 177 MB/s

**工作量**：约 2 小时

---

### 3.2 后台预初始化线程（解决首次 I/O 200ms 惩罚）

**问题根因**：
- `cudaSetDevice()` + `cudaStreamCreate()` + `cudaMalloc()`（~6 MB 显存池）累计约 200 ms
- 当前 lazy init 在第一次 I/O 时执行，阻塞 read() 返回

**实验证据**：
- GPU 路径首次 read：~200 ms
- CPU 路径首次 read：~30-55 ms

**优化方案**：

```c
// hook.c — constructor 中启动后台预初始化线程
static pthread_once_t g_preinit_once = PTHREAD_ONCE_INIT;
static volatile int g_preinit_done = 0;

static void *preinit_thread(void *arg) {
    (void)arg;
    ensure_backend_init();  // 提前完成 CUDA init
    g_preinit_done = 1;
    return NULL;
}

static void spawn_preinit(void) {
    pthread_t t;
    pthread_create(&t, NULL, preinit_thread, NULL);
    pthread_detach(t);
}

void __attribute__((constructor(101))) hook_init(void) {
    // ... 原有逻辑 ...
    pthread_once(&g_preinit_once, spawn_preinit);
}

// 在 ensure_backend_init() 中：
if (!g_preinit_done) {
    // 后台线程还没完成，但当前线程不能等 200ms
    // 方案 A：直接 fallback CPU，等后台完成后再切 GPU
    // 方案 B：阻塞等待（保持现有行为）
}
```

**预期效果**：
- 长生命周期应用（数据库、后台服务）：首次 I/O 降至 **<10 ms**（与 CPU 路径持平）
- 短生命周期命令（ls/cat）：仍需 fallback CPU 或接受延迟

**工作量**：约 1.5 小时

---

## 四、P2 — 低优先级优化

### 4.1 LRU Block Cache（解决小块随机读 IOPS 瓶颈）

**问题根因**：
- 4k 随机读仍需解压整个 128k block，然后裁剪
- IOPS 被锁定在 ~800，与 bs 大小无关

**优化方案**：

```c
// hook.c — 简单的 per-fd LRU cache
#define BLOCK_CACHE_SIZE 4  // 缓存最近 4 个 block

typedef struct {
    uint32_t block_id;
    uint8_t *data;  // GPUC_BLOCK_SIZE 字节
    int valid;
} block_cache_entry_t;

struct fd_info {
    // ... 原有字段 ...
    block_cache_entry_t block_cache[BLOCK_CACHE_SIZE];
    int cache_next_evict;
};

// 在 read_compressed_at() 中：
// 1. 先查 cache
for (int i = 0; i < BLOCK_CACHE_SIZE; i++) {
    if (info->block_cache[i].valid && info->block_cache[i].block_id == first_block) {
        memcpy(out_ptr, info->block_cache[i].data + first_block_off, to_copy);
        // cache hit!
        return ...;
    }
}
// 2. cache miss 时解压并放入 cache
// ... 解压后 ...
int slot = info->cache_next_evict % BLOCK_CACHE_SIZE;
info->block_cache[slot].block_id = first_block;
memcpy(info->block_cache[slot].data, decompressed_block, GPUC_BLOCK_SIZE);
info->block_cache[slot].valid = 1;
info->cache_next_evict++;
```

**预期效果**：
- 随机读有局部性时（如数据库 B-tree 页）：IOPS 从 800 提升至 **2000-3000**
- 纯随机（无局部性）：无改善

**工作量**：约 2 小时

---

### 4.2 延迟 Header 写入（降低写路径开销）

**问题根因**：
- `open()` 时立即写入 56 字节 RAW header，导致额外的磁盘 I/O
- Hook RAW 写入比 Baseline 慢 13.5%

**优化方案**：

```c
// hook.c — 延迟 header 写入
struct fd_info {
    // ... 原有字段 ...
    int header_pending;  // header 尚未写入磁盘
};

int open(...) {
    // ... 原有逻辑 ...
    // 不立即写 header，只标记 pending
    info->header_pending = 1;
    return fd;
}

ssize_t write(int fd, const void *buf, size_t count) {
    fd_info_t *info = get_fd_info(fd);
    if (info && info->header_pending) {
        // 首次写入时，先写 header，再写数据
        real_pwrite64(fd, &info->hdr, sizeof(info->hdr), 0);
        info->header_pending = 0;
    }
    // ... 原有写入逻辑 ...
}
```

**预期效果**：
- 只 open 不 write 的文件（如 `touch`）：零 header 开销
- 正常写入场景：减少一次磁盘 seek，写入带宽提升 **10-15%**

**工作量**：约 1 小时

---

## 五、执行建议（2026-06-10 更新）

| 顺序 | 优化项 | 预计收益 | 工作量 | 状态 |
|------|--------|---------|--------|------|
| 1 | 多 CUDA Stream 并行 | **未达预期**（理论 10-15x，实际 ~1x） | 2h | ✅ 已实现 |
| 2 | CRC32 验证跳过 | **未达预期**（理论 1.5-2x，实际 1.04x） | 0.5h | ✅ 已实现 |
| 3 | mmap 预解压前 N MB | **很高**（5-10x） | 3h | 待实现 |
| 4 | 高优先级 Stream + 负载检测 | **高**（2-5x） | 2h | 待实现 |
| 5 | 后台预初始化线程 | **中**（消除 200ms） | 1.5h | 待实现 |
| 6 | LRU Block Cache | **中**（2-4x IOPS） | 2h | 待实现 |
| 7 | 延迟 Header 写入 | **低**（10-15%） | 1h | 待实现 |

> **核心结论**：多 CUDA Stream 和 CRC32 跳过均已实现，但**未解决 jobs=32 骤降问题**。根因是 fio sync 引擎 128k bs 下每次 read 仅处理 1 个 block，kernel 启动开销无法被多 Stream 摊销。
>
> **下一步建议**：
> 1. 若需解决 jobs=32 性能：改用 **异步 I/O 引擎**（如 `io_uring` + 深度≥16）或 **bs≥1M**，使单次 read 覆盖多 block
> 2. 若需提升单线程极限：聚焦 **GPU kernel 启动延迟优化**（如 CUDA Graph）或 **更大 batch 合并**
> 3. 若需提升 mmap 场景：优先实现 **mmap 按需解压**（预解压前 16 MB + 后台线程）
