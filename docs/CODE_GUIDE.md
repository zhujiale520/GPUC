# GPUC Code Guide

> 目标：帮你彻底读懂 `gpu_compress/` 目录下的每一行代码（更新至 2026-06-02）

---

## 一、总体架构（先记住这张图）

```
┌─────────────────────────────────────────────────────────────┐
│  用户态应用 (fio, cp, dd, 数据库, test_hook, mmap_test...)  │
├─────────────────────────────────────────────────────────────┤
│  LD_PRELOAD 拦截层 (libgpuhook.so / libcpuhook.so)          │
│    ├─ src/hook.c          ← 1456 行，核心拦截逻辑          │
│    ├─ src/gpu_compress.cu ← 495 行，CUDA 压缩/解压         │
│    ├─ src/cpu_compress.c  ← 212 行，纯 CPU 对比基准        │
│    └─ include/gpu_compress_api.h  ← C API 头文件           │
├─────────────────────────────────────────────────────────────┤
│  离线压缩 Daemon (gpu_compress_daemon)                       │
│    └─ src/daemon.c        ← 464 行，后台扫描+压缩          │
├─────────────────────────────────────────────────────────────┤
│  底层文件系统 (ext4 / xfs)  ← 完全不改                       │
└─────────────────────────────────────────────────────────────┘
```

**四大模块**：
1. **格式层** (`file_header.h`)：定义 GPUC 文件格式
2. **算法层** (`gpu_compress.cu` + `cpu_compress.c` + `.cuh`)：CUDA / CPU 压缩解压
3. **应用层** (`hook.c` + `daemon.c`)：透明拦截 + 后台压缩
4. **测试层** (`tests/`)：单元测试、集成测试、fio 基准

---

## 二、阅读路线图（建议顺序）

| 顺序 | 文件 | 为什么先读它 | 代码量 |
|------|------|-------------|--------|
| 1 | `include/file_header.h` | 只有 85 行，看懂"文件长什么样" | ~85 行 |
| 2 | `include/gpu_compress_api.h` | 只有 44 行，看懂"对外暴露哪些函数" | ~44 行 |
| 3 | `src/cpu_compress.c` | 212 行，纯 CPU 实现，算法逻辑最清晰 | ~212 行 |
| 4 | `src/daemon.c` | 464 行，看懂"后台怎么压缩文件" | ~464 行 |
| 5 | `src/hook.c` | 1456 行，最复杂，但前面懂了再读它就很清晰 | ~1456 行 |
| 6 | `src/gpu_compress.cu` | 495 行，算法 CUDA 化细节，最后读 | ~495 行 |
| 7 | `tests/` 下的测试 | 验证你的理解 | ~600 行 |

---

## 三、逐个文件详解

---

### 3.1 `include/file_header.h` — 文件格式定义（85 行）

**核心概念**：每个被管理的文件开头附加一个 **GPUC Header**，让 hook 能识别这个文件是"我们管的"。

```c
#define GPUC_MAGIC       0x47505543   // 小端序就是 "GPUC"
#define GPUC_BLOCK_SIZE  (128 * 1024) // 128KB 固定块
```

**两个结构体**：

```c
struct gpuc_header {
    uint32_t magic;          // [0:4]   魔数，识别文件类型
    uint32_t version;        // [4:8]   版本号
    uint64_t orig_size;      // [8:16]  原始逻辑大小（COMPRESSED 状态有效）
    uint32_t block_size;     // [16:20] 固定 128KB
    uint32_t num_blocks;     // [20:24] 总块数
    uint8_t  state;          // [24]    0=RAW, 1=COMPRESSED, 2=BUSY
    uint8_t  comp_algo;      // [25]    1=SGLZ
    uint16_t reserved;       // [26:28] 预留对齐
    uint64_t header_size;    // [32:40] 头+索引表总大小（8字节对齐）
    uint64_t mtime;          // [40:48] 修改时间
    uint64_t ctime;          // [48:56] 创建时间
};
// 实际 sizeof(struct gpuc_header) = 56 字节（非 64 字节）
// reserved 后到 header_size 之间有 4 字节 padding（编译器自动插入）
```

```c
struct gpuc_block_entry {
    uint32_t orig_len;       // 原始长度（通常 128K，最后一块可能不足）
    uint32_t comp_len;       // 压缩后长度
    uint64_t offset;         // 该块在文件中的物理偏移
};
```

**关键理解**：
- Header 固定在文件开头，**实际 56 字节**（header 注释说 64 字节是不准确的）
- Header 后面紧跟 **块索引表**：`num_blocks * sizeof(gpuc_block_entry)` 字节
- 索引表后面才是**真正的数据**
- `hook.c` 读文件时，先读 header，就知道每个 128KB 块存在哪里、压成多大了
- **RAW 状态的 `orig_size` 为 0**（设计如此）：RAW 文件的逻辑大小 = 物理大小 - header_size，由 `get_logical_size()` 计算
- COMPRESSED 状态的 `orig_size` 由 daemon 在压缩时写入

**辅助函数**：
- `gpuc_header_total_size(num_blocks)`：计算头+索引表总大小
- `gpuc_num_blocks(file_size)`：根据文件大小计算需要几块
- `gpuc_is_header(buf)`：判断一个 buffer 是不是 GPUC 文件头

---

### 3.2 `include/gpu_compress_api.h` — C API（44 行）

这是**纯 C 代码**可以包含的头文件，不依赖 CUDA。

```c
#define GC_BLOCK_SIZE   (128 * 1024)   // 128KB
#define GC_CHUNK_SIZE   4096           // 4KB
#define GC_NCHUNKS      32             // 32 * 4KB = 128KB
#define GC_SLOT_SIZE    (GC_CHUNK_SIZE + 256)  // 4352 字节
```

**对外暴露两套 API**（GPU + CPU，接口完全一致）：

```c
/* GPU Backend */
int  gpu_compress_init(void);
void gpu_compress_fini(void);
int gpu_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap);
int gpu_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len);
int gpu_decompress_batch(int n,
                         const uint8_t **in_bufs, const size_t *in_lens,
                         uint8_t **out_bufs, const size_t *out_lens);
int gpu_tls_alloc_pinned(void **ptr, size_t size);   // 新增：pinned memory 分配
void gpu_tls_free_pinned(void *ptr);                  // 新增：pinned memory 释放

/* CPU Backend（fallback / 对比基准） */
int  cpu_compress_init(void);
void cpu_compress_fini(void);
int cpu_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap);
int cpu_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len);
int cpu_decompress_batch(int n,
                         const uint8_t **in_bufs, const size_t *in_lens,
                         uint8_t **out_bufs, const size_t *out_lens);
```

**为什么有 SLOT_SIZE？**
- 每个 4KB chunk 压缩后可能变大（最坏情况原始数据+少量 overhead）
- 所以给每个 chunk 分配 `4096 + 256 = 4352` 字节的"slot"
- GPU 内核处理时，每个线程/块处理一个固定大小的 slot，便于并行寻址
- 但**写入磁盘时**用的是紧凑格式（只写实际长度），不浪费空间

---

### 3.3 `src/cpu_compress.c` — 纯 CPU 实现（212 行）

**用途**：作为 GPU offload 方案的对比基准，同时作为 **GPU 失败时的 fallback backend**。

**算法与 `gpu_compress.cu` 完全一致**，仅在 CPU 上串行执行：
- `sglz_compress_chunk_cpu()`：每个 chunk 的 LZ77 压缩
- `sglz_decompress_chunk_cpu()`：每个 chunk 的解压
- `cpu_compress_block()`：打包 32 个 chunks
- `cpu_decompress_block()`：解压 32 个 chunks
- `cpu_decompress_batch()`：批量循环调用 `cpu_decompress_block()`

**为什么需要它？**
1. **对比基准**：证明 GPU offload 真的有性能提升
2. **CPU Fallback**：当 GPU 不可用时（`cudaSetDevice` 失败、驱动问题、GPU 被占用），hook 自动切换到 CPU backend，程序不崩溃

---

### 3.4 `src/daemon.c` — 离线压缩 Daemon（464 行）

**职责**：后台扫描目录，发现 RAW 文件，逐块 GPU 压缩，原子替换。

**主流程**（对应 `main()` 函数）：
```
解析参数 (-r 递归, -d 守护模式)
  ↓
gpu_compress_init() 初始化 CUDA
  ↓
scan_directory(dir, recursive, &processed_list) 扫描目录
  ↓
gpu_compress_fini() 清理
```

**增量扫描**（新增）：
- `struct processed_entry` 链表记录已处理文件的路径和 mtime
- `is_skippable()`：若文件 mtime 未变则跳过，避免重复 open/read header
- `mark_processed()`：压缩成功后标记

**扫描流程**（`scan_directory()`）：
```
打开目录
  ↓
遍历每个文件（跳过 . 开头和 .gpuc_tmp 结尾的）
  ↓
如果是目录且 -r 开启 → 递归扫描
  ↓
如果是普通文件 → is_skippable 检查（增量过滤）
  ↓
如果是 RAW 状态 → compress_one_file(path) 压缩
  ↓
标记为已处理（无论是否压缩）
```

**单文件压缩流程**（`compress_one_file()`，核心）：

```
1. 打开源文件，尝试 flock(LOCK_EX | LOCK_NB) 非阻塞锁
   - 若文件正被其他进程使用则跳过
   ↓
2. 读取旧 header，确认是 RAW 状态
   ↓
3. 创建临时文件：原文件名 + ".gpuc_tmp"
   ↓
4. 在新文件开头写入【占位 header + 占位索引表】
   ↓
5. 批量处理（BATCH_SIZE=32 blocks/批）：
   a. pread64 读取最多 32 个 128KB 原始数据
   b. sglz_compress_batch() GPU 批量压缩（一次 kernel 启动）
   c. 对每个块：slot 布局 → 紧凑布局（去掉多余填充）
   d. 写入紧凑数据，或原始数据（fallback）
   e. 用 lseek + 单字节写制造 128KB 对齐空洞（稀疏文件）
   f. 记录 blocks[i] = {orig_len, comp_len, offset}
   ↓
6. 回填：lseek 到文件开头，写入真正的 header 和索引表
   ↓
7. close 两个文件
   ↓
8. rename(tmp_path, path) 原子替换
   ↓
9. 删除临时文件（如果失败）
```

**关键改进**：daemon 现在也使用 `sglz_compress_batch()`（一次处理 32 blocks），而非逐块压缩，大幅减少了 kernel 启动次数。

---

### 3.5 `src/hook.c` — LD_PRELOAD 拦截层（1456 行）

这是最复杂的文件。分四个层次理解：

#### 第一层：函数指针 + 初始化（hook_init）

```c
static ssize_t (*real_read)(int, void *, size_t);
static int     (*real_open)(const char *, int, ...);
// ... 共 25+ 个函数指针
```

`hook_init()` 在共享库加载时自动执行（`__attribute__((constructor(101)))`）：
```c
real_read = dlsym(RTLD_NEXT, "read");
real_open = dlsym(RTLD_NEXT, "open");
// ...
```

`RTLD_NEXT` 的意思是：跳过当前 .so 自己，去找下一个（也就是 glibc）里的同名函数。

#### 第二层：Backend 选择 + Lazy Init + CPU Fallback

```c
static int  (*g_backend_compress_init)(void);
static void (*g_backend_compress_fini)(void);
static int  (*g_backend_decompress_128k)(...);
static int  (*g_backend_decompress_batch)(...);
static const char *g_backend_name = "gpu";
static int g_backend_initialized = 0;
```

**Lazy Init（延迟初始化）**：
- `hook_init()` 中**不立即调用** `gpu_compress_init()`
- 只设置函数指针：`g_backend_compress_init = gpu_compress_init`
- 第一次 I/O 时（`ensure_backend_init()` 通过 `pthread_once`）才实际初始化
- 解决 CUDA 在 constructor 阶段可能未就绪的问题

**CPU Fallback（自动回退）**：
```c
static void do_backend_init(void) {
    if (!g_backend_initialized && g_backend_compress_init) {
        int ret = g_backend_compress_init();
        if (ret == 0) {
            g_backend_initialized = 1;
        } else if (g_backend_compress_init == gpu_compress_init) {
            // GPU init failed, fallback to CPU
            fprintf(stderr, "[HOOK] GPU lazy init failed (ret=%d), fallback to CPU backend\n", ret);
            g_backend_name = "cpu-fallback";
            g_backend_compress_init = cpu_compress_init;
            g_backend_compress_fini = cpu_compress_fini;
            g_backend_decompress_128k = cpu_decompress_128k;
            g_backend_decompress_batch = cpu_decompress_batch;
            if (g_backend_compress_init() == 0) g_backend_initialized = 1;
        }
    }
}
```

- 用户可通过环境变量 `GPUCOMPRESS_BACKEND=cpu` 强制使用 CPU
- 用户可通过 `CUDA_VISIBLE_DEVICES=""` 模拟无 GPU 环境
- 用户可通过 `GPUC_NO_HOOK=1` 完全禁用 hook

#### 第三层：fd 管理表 + mmap 跟踪表

```c
#define MAX_FD 65536
static fd_info_t *g_fd_table[MAX_FD];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
```

每个被 hook 的 fd 对应一个 `fd_info_t` 结构：
```c
typedef struct {
    int active;                    // 是否在使用
    int has_header;                // 是否已读取/写入 header
    int is_compressed;             // 是否是 COMPRESSED 状态
    struct gpuc_header hdr;        // 文件头副本
    struct gpuc_block_entry *blocks;  // 块索引表（压缩文件才有）
    off64_t cur_offset;            // 逻辑当前偏移（用户视角）
    off64_t phys_size;             // 物理文件大小
} fd_info_t;
```

**mmap 跟踪表**：
```c
#define MAX_MMAP_TRACK 64
typedef struct {
    int uffd;
    int fd;
    uint8_t *block;
    fd_info_t *info;
    pthread_t thread;
    // 映射区间、逻辑 offset、stop/failed
} mmap_uffd_ctx_t;

typedef struct {
    void *addr;       // 返回给应用的地址
    size_t len;       // 映射长度
    size_t buf_len;   // 页对齐后的完整映射长度
    int active;
    mmap_uffd_ctx_t *uffd; // 同步回退时为 NULL
} mmap_track_t;
```
- 默认通过 userfaultfd 对 RAW/INLINE/COMPRESSED 按 128 KiB block 填充
- 不支持 userfaultfd 的内核同步填充完整匿名映射
- 完整 `munmap` 关闭 userfaultfd、等待 handler 并释放匿名映射；部分 unmap 拒绝
- `msync` 对匿名映射直接返回成功

**辅助函数**：
- `get_fd_info(fd)`：查表（加 mutex 锁）
- `set_fd_info(fd, info)`：把 info 放进表（加锁，自动清理旧 entry）
- `clear_fd_info(fd)`：关闭时清理（free blocks，释放内存）
- `add_mmap_track()` 与 mmap 表锁：记录和回收完整映射

#### 第四层：拦截函数逐个解释

**拦截的系统调用列表（19+ 个）**：
```
open / open64 / creat / openat / openat64
read / write / pread64 / pwrite64 / readv / writev
lseek / lseek64 / close / dup / dup2 / dup3
mmap / munmap / msync
__fxstat / __fxstat64 / __xstat / __xstat64 / __lxstat / __lxstat64
ftruncate / truncate / sendfile
```

**`open` / `open64` / `openat` / `openat64` / `creat`**

所有 open 变体的逻辑几乎一样：

```c
int open(const char *pathname, int flags, ...) {
    // 1. 调用真正的 open
    int fd = real_open(pathname, flags, mode);
    if (fd < 0) return fd;
    
    // 2. 【关键保护】只处理普通文件，跳过 sysfs/procfs/管道
    if (!is_regular_file(fd)) return fd;
    
    // 3. 分配 info 结构
    fd_info_t *info = calloc(1, sizeof(fd_info_t));
    info->phys_size = get_phys_size(fd);  // fstat 看文件多大
    
    // 4. 新文件（空文件或 O_CREAT）→ 写 RAW header
    if (info->phys_size == 0) {
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    }
    // 5. 已有文件且够大 → 尝试读取 header
    else if (info->phys_size >= sizeof(struct gpuc_header)) {
        read_header(fd, info);
    }
    
    set_fd_info(fd, info);
    return fd;
}
```

**`write`**

```c
ssize_t write(int fd, const void *buf, size_t count) {
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_write(fd, buf, count);  // 不是我们管的文件
    }
    // 对已压缩文件拒绝写入（防止破坏块索引结构）
    if (info->is_compressed) {
        errno = EROFS;
        return -1;
    }
    off64_t phys_off = info->cur_offset + info->hdr.header_size;
    ssize_t ret = real_pwrite64(fd, buf, count, phys_off);
    if (ret > 0) {
        info->cur_offset += ret;
        info->phys_size = get_phys_size(fd);
    }
    return ret;
}
```

**`read` — 分两种情况**

```c
ssize_t read(int fd, void *buf, size_t count) {
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_read(fd, buf, count);  // 透传
    }
    if (info->is_compressed) {
        return read_compressed(fd, info, buf, count);  // GPU 批量解压
    }
    return read_raw(fd, info, buf, count);  // RAW：跳过 header
}
```

**`read_raw`**（简单）：
```c
static ssize_t read_raw(int fd, fd_info_t *info, void *buf, size_t count) {
    off64_t phys_off = info->cur_offset + info->hdr.header_size;
    ssize_t ret = real_pread64(fd, buf, count, phys_off);
    if (ret > 0) info->cur_offset += ret;
    return ret;
}
```

**`read_compressed`**（最核心，约 85 行，**批量解压**）：

```c
static ssize_t read_compressed(int fd, fd_info_t *info, void *buf, size_t count) {
    ensure_backend_init();  // 延迟初始化 GPU/CPU backend
    if (ensure_tls_buffers() != 0 || ensure_batch_tls_buffers() != 0) {
        errno = ENOMEM; return -1;
    }
    
    off64_t start = info->cur_offset;
    off64_t log_size = get_logical_size(info);
    if (start >= log_size) return 0;
    
    uint8_t *out_ptr = (uint8_t *)buf;
    size_t total_read = 0;
    
    while (count > 0) {
        // 1. 计算本次批量需要多少块（最多 16 块）
        uint32_t first_block = (uint32_t)(start / GPUC_BLOCK_SIZE);
        uint32_t last_block = (uint32_t)((start + count - 1) / GPUC_BLOCK_SIZE);
        int nblocks = (int)(last_block - first_block + 1);
        if (nblocks > MAX_BATCH_BLOCKS) nblocks = MAX_BATCH_BLOCKS;
        
        // 2. Phase 1: 从磁盘读取所有压缩块并转为 slot 布局
        for (int i = 0; i < nblocks; i++) {
            uint32_t bid = first_block + i;
            struct gpuc_block_entry *be = &info->blocks[bid];
            uint8_t *comp_slot = g_tls_batch_comp_bufs + i * GC_NCHUNKS * GC_SLOT_SIZE;
            
            // 读取紧凑格式
            real_pread64(fd, g_tls_comp_buf, be->comp_len, be->offset);
            
            // 紧凑格式 → slot 布局
            int file_pos = 0;
            for (int j = 0; j < GC_NCHUNKS && file_pos < be->comp_len; j++) {
                uint16_t chunk_len = *(uint16_t *)(g_tls_comp_buf + file_pos);
                if (chunk_len == 0xFFFF) chunk_len = 2 + GC_CHUNK_SIZE;
                memcpy(comp_slot + j * GC_SLOT_SIZE, g_tls_comp_buf + file_pos, chunk_len);
                file_pos += chunk_len;
            }
            
            g_tls_batch_in_ptrs[i] = comp_slot;
            g_tls_batch_in_lens[i] = GC_NCHUNKS * GC_SLOT_SIZE;
            g_tls_batch_out_ptrs[i] = g_tls_batch_decomp_bufs + i * GPUC_BLOCK_SIZE;
            g_tls_batch_out_lens[i] = be->orig_len;
        }
        
        // 3. Phase 2: 批量 GPU/CPU 解压（一次调用）
        int decomp_ret = g_backend_decompress_batch(nblocks, ...);
        
        // 4. Phase 3: 拷贝到用户 buffer
        for (int i = 0; i < nblocks && count > 0; i++) {
            off64_t block_off = (i == 0) ? first_block_off : 0;
            size_t to_copy = GPUC_BLOCK_SIZE - block_off;
            if (to_copy > count) to_copy = count;
            memcpy(out_ptr, g_tls_batch_decomp_bufs + i * GPUC_BLOCK_SIZE + block_off, to_copy);
            out_ptr += to_copy; start += to_copy; count -= to_copy; total_read += to_copy;
        }
    }
    
    info->cur_offset = start;
    return (ssize_t)total_read;
}
```

**关键优化**：
- Hook 的 SGLZ 默认 `MAX_BATCH_BLOCKS = 4`：一次处理 4 个 128KB 块
  （512 KiB）；后端 device pool 保留最大 32-block 容量
- `__thread` TLS 缓冲区：每个线程独立的压缩/解压缓冲区，避免多线程竞争
- `tls_alloc` / `tls_free` 宏：GPU build 时自动使用 `cudaHostAlloc`（pinned memory），失败时 fallback 到 `malloc`

**`pread64` / `read_compressed_at`**

与 `read_compressed` 几乎一样，但**不修改 `cur_offset`**（因为 pread 是"位置无关读"）。

**`lseek` / `lseek64`**

```c
off64_t lseek64(int fd, off64_t offset, int whence) {
    // 计算新的逻辑偏移
    switch (whence) {
        case SEEK_SET: new_off = offset; break;
        case SEEK_CUR: new_off = info->cur_offset + offset; break;
        case SEEK_END: new_off = log_size + offset; break;
    }
    info->cur_offset = new_off;
    
    // 同步底层物理偏移（让 pread/pwrite 能正常工作）
    off64_t phys_off = new_off + info->hdr.header_size;
    real_lseek64(fd, phys_off, SEEK_SET);
    
    return new_off;  // 返回逻辑偏移给用户
}
```

**`__fxstat` / `__fxstat64` / `__xstat` / `__xstat64` / `__lxstat` / `__lxstat64`**（fstat/stat/lstat 拦截）

```c
int __fxstat64(int ver, int fd, struct stat64 *buf) {
    int ret = real_fxstat64(ver, fd, buf);  // 先调真正的 fstat
    if (ret == 0) {
        fd_info_t *info = get_fd_info(fd);
        if (info && info->has_header) {
            buf->st_size = get_logical_size(info);  // 伪装为逻辑大小
        }
    }
    return ret;
}
```

为什么拦截 stat 全家桶？
- 让 `ls -l` 显示逻辑大小而非物理稀疏大小
- `__xstat` 拦截路径名查询，`__lxstat` 拦截符号链接查询
- 内部实现 `adjust_stat_size()` / `adjust_stat64_size()`：临时 open 文件读取 header 判断

**`mmap` / `munmap` / `msync`**（新增）

```c
void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    // 只处理受管 GPUC 文件的 MAP_PRIVATE 映射
    if (!info || !info->has_header) {
        return real_mmap(addr, length, prot, flags, fd, offset);
    }
    if (!(flags & MAP_PRIVATE) || (flags & MAP_FIXED)) {
        errno = EOPNOTSUPP;
        return MAP_FAILED;
    }
    // auto: setup_userfaultfd_mapping()；失败则同步完整填充
    // userfaultfd: 失败直接 EOPNOTSUPP
    // sync: mmap_sync_fill()
}
```

handler 在 `poll()` 收到 fault 后，将地址换算为 GPUC block，读取/解压整个
128 KiB block，再用 `UFFDIO_COPY` 填充与映射相交的区间。完整扫描成本被推迟到
访问阶段，并未消失。

**`sendfile`**（新增）

对 COMPRESSED 文件 fallback 到 `read + write` 循环（因为 sendfile 走内核零拷贝，不经过用户态 hook）。

**`dup` / `dup2` / `dup3`**（新增）

复制 fd 时同步复制 `fd_info_t`（包括 `blocks` 索引表的深拷贝），支持 `dd` 等工具。

**`ftruncate` / `truncate`**（新增）

对 GPUC 文件调整截断长度时保留 header 空间（物理长度 = 逻辑长度 + header_size）。

**`readv` / `writev`**（新增）

`readv` 对压缩文件逐个 iov 用 `read()` 模拟；`writev` 对 RAW 文件直接透传（底层偏移已由 lseek 同步）。

---

### 3.6 `src/gpu_compress.cu` — CUDA 压缩/解压算法（495 行）

这是纯技术实现。核心理解以下几点即可：

#### 架构设计

```
128KB block
  ├─ chunk 0  (4KB)  ← CUDA block 0 处理
  ├─ chunk 1  (4KB)  ← CUDA block 1 处理
  ├─ ...
  └─ chunk 31 (4KB)  ← CUDA block 31 处理
```

- 1 个 CUDA block = 256 threads（实际由 `SGLZ_COMPRESS_TPB=64` 控制）
- 1 个 block 处理 1 个 4KB chunk
- 32 个 blocks 并行处理 1 个 128KB block

#### 压缩内核（`sglz_compress_chunks_kernel`）

每个 thread 处理 chunk 中的一部分：
1. 建立 3-byte hash 表（滑动窗口 2048 B）
2. 查找最长匹配（LZ77）
3. 输出：2-byte 长度前缀 + 匹配串/字面量
4. hash 表放在 **shared memory**（stride layout 避免 bank conflict）

#### 解压内核（`sglz_decompress_chunks_kernel`）

反向操作：读 2-byte 长度，决定是拷贝字面量还是从历史窗口拷贝。

#### Host 包装函数

**`sglz_init()`** — 初始化（新增 device memory pool）：
```c
int sglz_init(void) {
    cudaSetDevice(0);
    cudaFuncSetAttribute(sglz_compress_chunks_kernel,
                         cudaFuncAttributeMaxDynamicSharedMemorySize, 64KB);
    cudaStreamCreate(&g_stream);  // 异步 stream
    
    // 预分配 batch decompress 的 device 内存池（~6MB）
    cudaMalloc(&g_d_batch_in,  MAX_BATCH * 32 * 4352);
    cudaMalloc(&g_d_batch_out, Max_BATCH * 128KB);
    cudaMalloc(&g_d_batch_out_lens, Max_BATCH * sizeof(size_t));
}
```

**`sglz_compress_batch()`** — 批量压缩：
- 一次性分配所有 device 内存（`total_in = n * 128KB`, `total_out = n * 32 * 4352`）
- `cudaMemcpyAsync` H→D 所有输入
- 启动一个 kernel 处理所有 `n * 32` 个 chunks
- `cudaStreamSynchronize` 等待完成
- 拷回输出长度和数据

**`sglz_decompress_batch()`** — 批量解压（使用 device memory pool）：
```c
int sglz_decompress_batch(int n, ...) {
    // 使用预分配的 device 内存，无需 cudaMalloc/cudaFree！
    uint8_t *d_in = (uint8_t *)g_d_batch_in;
    uint8_t *d_out = (uint8_t *)g_d_batch_out;
    size_t *d_out_lens = (size_t *)g_d_batch_out_lens;
    
    for (int i = 0; i < n; i++) {
        cudaMemcpyAsync(d_in + i * 32 * 4352, in_bufs[i], ..., H2D, g_stream);
    }
    cudaMemcpyAsync(d_out_lens, out_lens, ..., H2D, g_stream);
    
    // 启动 kernel：num_blocks = (n*32 + 255) / 256
    sglz_decompress_chunks_kernel<<<num_blocks, 256, 0, g_stream>>>(...);
    cudaStreamSynchronize(g_stream);
    
    for (int i = 0; i < n; i++) {
        cudaMemcpy(out_bufs[i], d_out + i * 128KB, out_lens[i], D2H);
    }
    return n;
}
```

**`gpu_tls_alloc_pinned()` / `gpu_tls_free_pinned()`** — Pinned Memory：
- `cudaHostAlloc` 分配页锁定内存
- H2D/D2H 拷贝时无需 driver 中转 memcpy
- 若 CUDA 不可用则返回 -1，hook 自动 fallback 到 `malloc`

#### 为什么分 chunk？

- **并行性**：32 个 chunks 可以同时被 32 个 CUDA blocks 处理
- **随机读**：用户只读 128KB 中的一部分时，只需解压对应 chunk
- **容错**：某个 chunk 不可压缩不影响其他 chunk

---

### 3.7 测试文件

#### `src/test_compress.c` — 单元测试（~146 行）

测试三个场景：
1. **可压缩数据**：重复模式，验证压缩率 ~8.7%，解压后数据一致
2. **随机数据**：验证返回 0（fallback，不压缩）
3. **全零数据**：验证压缩率 ~2.2%，解压后数据一致

#### `src/test_hook.c` — Hook 测试程序（~100 行）

一个简单的 C 程序，用标准 `open/read/write` 读写文件：
```bash
# 写测试
LD_PRELOAD=./bin/libgpuhook.so ./bin/test_hook write /tmp/test.bin 262144

# 读测试（验证数据一致性）
LD_PRELOAD=./bin/libgpuhook.so ./bin/test_hook read /tmp/test.bin 262144
```

#### `tests/test_integration.sh` — 集成测试（~73 行）

端到端验证完整流程：
```
[1] 编译 test_hook
[2] LD_PRELOAD 写入文件
[3] 检查物理文件是否有 GPUC header
[4] LD_PRELOAD 读取 RAW 文件
[5] 运行 Daemon 压缩
[6] 检查文件状态变为 COMPRESSED
[7] LD_PRELOAD 读取压缩文件（自动 GPU 解压）
```

#### `tests/benchmark_fio.sh` — fio 基准测试（~360 行）

跑多组测试，对比 baseline vs hook：
1. baseline_write（无 hook）
2. baseline_read（无 hook）
3. hook_write（有 hook，写 RAW）
4. hook_raw_read（有 hook，读 RAW）
5. hook_compressed_read（有 hook，Daemon 压缩后 GPU 解压读）

---

## 四、五条数据流（理解这些就全懂了）

### 流 1：应用写新文件

```
应用调用 write(fd, buf, count)
  ↓
hook.c 的 write() 被调用
  ↓
get_fd_info(fd) → 找到 info（open 时创建的）
  ↓
info->has_header == true（open 时写的 RAW header）
  ↓
检查 info->is_compressed，若为 true 则拒绝写入（EROFS）
  ↓
phys_off = cur_offset + header_size(56)
  ↓
pwrite64(fd, buf, count, phys_off)  // 写到物理偏移 56 之后
  ↓
更新 cur_offset
```

### 流 2：应用读 RAW 文件

```
应用调用 read(fd, buf, count)
  ↓
hook.c 的 read() 被调用
  ↓
get_fd_info(fd) → info->is_compressed == false
  ↓
read_raw()：phys_off = cur_offset + 56
  ↓
pread64(fd, buf, count, phys_off)  // 从 56 之后读
  ↓
返回原始数据（用户无感知）
```

### 流 3：Daemon 压缩文件

```
daemon.c 扫描目录发现 RAW 文件
  ↓
flock(LOCK_EX | LOCK_NB) 尝试非阻塞锁
  ↓
compress_one_file(path)
  ↓
批量读取原始数据（跳过旧 header，32 blocks/批）
  ↓
sglz_compress_batch() → GPU 批量压缩
  ↓
逐块：slot 布局 → 紧凑格式
  ↓
写入临时文件
  ↓
lseek 制造 128KB 对齐空洞（稀疏文件）
  ↓
回填 header（state=COMPRESSED, orig_size=data_size）和块索引表
  ↓
rename(tmp, original) 原子替换
```

### 流 4：应用读压缩文件（GPU 批量解压）

```
应用调用 read(fd, buf, count)
  ↓
hook.c 的 read() 被调用
  ↓
get_fd_info(fd) → info->is_compressed == true
  ↓
read_compressed()
  ├─ ensure_backend_init() → 延迟初始化 GPU/CPU（pthread_once）
  ├─ 计算需要多少块（最多 16 块 = 2MB）
  ├─ Phase 1: 循环读取每个块的紧凑数据 → 转为 slot 布局
  ├─ Phase 2: g_backend_decompress_batch(nblocks, ...) → 批量 GPU/CPU 解压
  ├─ Phase 3: 从解压缓冲区拷贝用户请求的部分到 buf
  └─ 更新 cur_offset
  ↓
返回原始数据（对已加载 Hook 且走受支持 libc 接口的应用透明）
```

### 流 5：应用 mmap 压缩文件

```
应用调用 mmap(fd, length, PROT_READ, MAP_PRIVATE, ...)
  ↓
hook.c 的 mmap() 被调用
  ↓
get_fd_info(fd) → info->is_compressed == true
  ↓
分配匿名 missing 映射并注册 userfaultfd
  ↓
返回映射地址
  ↓
应用首次访问产生 missing fault
  ↓
handler 定位 128 KiB block → 读取/解压 → UFFDIO_COPY
  ↓
应用读取正确逻辑内容
```

如果内核不支持 userfaultfd，auto 模式同步填充完整映射；强制 userfaultfd 模式
返回 `EOPNOTSUPP`。具体能力矩阵见
[`SUPPORT_MATRIX.md`](SUPPORT_MATRIX.md)。

---

## 五、研发过程中遇到的问题和解决方法

### 5.1 六大 P0 优化（2026-06-02 完成）

| 优化 | 文件 | 问题与解决 |
|------|------|------|
| **Pinned Memory** | `gpu_compress.cu` | **问题**：TLS 缓冲区使用 `malloc`，每次 GPU 传输需 driver 中转 memcpy，实测带宽损失 ~40%。**解决**：改用 `cudaHostAlloc` 分配 page-locked 内存，消除中转拷贝。 |
| **CPU Fallback** | `hook.c` | **问题**：GPU 被占用或驱动异常时，LD_PRELOAD 拦截会导致所有 I/O 失败，程序崩溃。**解决**：GPU 初始化失败自动切换到 CPU backend（liblz4），程序零感知继续运行。 |
| **Lazy Init** | `hook.c` | **问题**：CUDA 在 shared library constructor 阶段初始化，此时 CUDA driver 可能尚未加载，导致 `cudaSetDevice` 失败。**解决**：第一次 I/O 操作时才初始化 CUDA，而非 `__attribute__((constructor))` 阶段。 |
| **Device Memory Pool** | `gpu_compress.cu` | **问题**：每次解压调用 `cudaMalloc/cudaFree`，开销占解压总时间 15-20%。**解决**：`sglz_init()` 预分配 6MB device 内存池，`sglz_decompress_batch()` 复用，消除动态分配开销。 |
| **Batch Decompress** | `hook.c` + `gpu_compress.cu` | **问题**：逐 block 解压时 kernel launch 和 memcpy 开销累积，小 I/O 场景下 GPU 优势被淹没。**解决**：一次处理最多 16 个 blocks，减少 kernel 启动次数和 H2D/D2H 拷贝轮次。 |
| **多线程并发** | `hook.c` | **问题**：共享缓冲区会产生数据竞争，全局 fd 表锁的临界区过大会阻塞并发 close。**解决**：解压工作缓冲区改为 `__thread` TLS；fd 表锁只保护表项和引用计数，CUDA 页锁定缓冲区在锁外释放。V100 上 SGLZ/LZ4、4/16/128 KiB、1/4 fio 线程五轮共 60/60 正常退出。 |

---

### 5.2 常见疑问解答

**Q1：为什么 hook 不拦截所有 mmap？**
A：已拦截 `mmap`/`munmap`/`msync`，但只支持 `MAP_PRIVATE` 读映射。`MAP_SHARED` 写映射暂不支持。

**Q2：为什么 daemon 不实时压缩？**
A：实时压缩会阻塞 write 系统调用，严重影响性能。离线压缩让写入速度 = 原生速度，后台慢慢压。

**Q3：fio 之前为什么段错误？**
A：fio 内部用 `pread64`/`readv` 做 I/O，且打开 `/sys/bus/nd/...` 等 sysfs 文件。早期 hook 没拦截这些函数，也没过滤非普通文件，导致把 sysfs 当作 GPUC 文件解析，内存越界访问。

**Q4：为什么 GPU 解压比 CPU 快？**
A：不是绝对快，是并行度高。32 个 chunks 同时解压，每个 chunk 用 256 threads。单线程 CPU LZ4 可能比我们的简化 LZ77 快，但 32 路并行后 GPU 总吞吐量可以覆盖 NVMe 带宽。

**Q5：comp_len == orig_len 时还算压缩吗？**
A：不算。daemon 中判断 `comp_size > 0 && comp_size < to_read` 才认为压缩成功。否则直接存原始数据。

**Q6：header 到底是 56 字节还是 64 字节？**
A：`sizeof(struct gpuc_header)` 实际为 **56 字节**。注释中的 64 字节不准确。布局为：magic(4)+version(4)+orig_size(8)+block_size(4)+num_blocks(4)+state(1)+comp_algo(1)+reserved(2)+padding(4)+header_size(8)+mtime(8)+ctime(8) = 56。

**Q7：RAW 状态的 orig_size 为什么是 0？**
A：设计如此。RAW 文件的逻辑大小由 `get_logical_size()` 动态计算为 `phys_size - header_size`。daemon 压缩时才会把实际的 `data_size` 写入 `orig_size`。

**Q8：GPU 被其他程序占用时怎么办？**
A：GPU 竞争会降低性能。当前默认路径不会在每次读取时自动切换 CPU；可使用
`GPUC_ENABLE_NVIDIA_SMI_FALLBACK=1` 做实验性负载检测，或显式部署 CPU Hook/Daemon。
比赛报告应给出并发负载实测数据，不能把一次 `cudaSetDevice` 结果当作稳定降级保证。

---

## 六、推荐阅读重点（如果没时间全读）

| 时间 | 读这些 | 目标 |
|------|--------|------|
| 10 分钟 | `file_header.h` + `gpu_compress_api.h` | 理解文件格式和 API |
| 20 分钟 | `cpu_compress.c` | 理解 SGLZ 算法逻辑（无 CUDA 干扰） |
| 20 分钟 | `daemon.c` 的 `compress_one_file()` | 理解压缩流程 |
| 30 分钟 | `hook.c` 的 `read_compressed()` + `do_backend_init()` | 理解批量解压和 fallback |
| 20 分钟 | 本导读的"五条数据流" | 建立整体认知 |

---

> 如果还有具体某一行代码看不懂，随时问我，我可以精确到行号解释。


## 七、合规与第三方声明

本项目严格遵循竞赛原创性与合规要求，详细声明文件请参见：

| 文件 | 内容 | 路径 |
|------|------|------|
| 第三方库声明 | 基础版本出处（nvCOMP、LZ4）、非本队来源说明、本队增量贡献 | [`THIRD_PARTY.md`](THIRD_PARTY.md) |
| AI 工具使用声明 | 使用的 AI 工具、用途、范围、代码行统计 | [`AI_TOOL_DECLARATION.md`](AI_TOOL_DECLARATION.md) |
| 开源许可 | 代码采用 Apache-2.0，文档采用 CC BY-SA 4.0 | [`LICENSE`](../LICENSE)、[`LICENSE-docs`](../LICENSE-docs) |
| 原创性声明 | README.md 底部原创性声明 | [`README.md`](../README.md) |

**核心要点**：

- **代码**：GPU 压缩加速（nvCOMP SGLZ/LZ4）、LD_PRELOAD 透明拦截、多进程并发压缩 — 均为本队增量开发。
- **基础框架来源**：环境搭建脚本、通用 Makefile 使用了公开模板，已做大幅修改适配本项目的 CUDA + nvCOMP 编译链。
- **AI 辅助**：使用了 ChatGPT (GPT-4o, o3) 和 Claude (Claude-4-Sonnet) 辅助编码与文档撰写，但所有架构设计、算法选择、性能测试由本队主导完成。
- **数据与实验**：所有基准测试数据均为本队在指定环境（V100 + CUDA 12.8）上自行采集，可直接复现。
