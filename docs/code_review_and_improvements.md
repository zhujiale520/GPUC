# GPU 存储压缩卸载 — 代码审查与优化建议

> 审查日期：2026-06-10
> 审查范围：`hook.c` / `gpu_compress.cu` / `daemon.c` / `file_header.h` / 测试脚本
> 目标：为 2026 系统能力大赛 OS 功能挑战赛道做最终冲刺优化

---

## 一、优先级总览

| 优先级 | 类别 | 数量 | 核心影响 |
|--------|------|------|---------|
| **P0** | 正确性/稳定性 | 4 项 | 崩溃、内存泄漏、数据损坏 |
| **P1** | 性能/鲁棒性 | 4 项 | 竞态条件、GPU 错误静默、OOM |
| **P2** | 工程化/测试 | 2 项 | 代码重复、测试覆盖不足 |

---

## 二、P0 — 比赛前必须修复

### 2.1 `hook.c`：多线程 `get_fd_info()` Use-After-Free

- **位置**：`hook.c:217-223`（`get_fd_info`），`hook.c:close/clear_fd_info`
- **问题**：`get_fd_info()` 返回 `fd_info_t*` 后立刻释放全局锁。后续操作（`read/write/lseek`）访问该指针时，其他线程可能同时 `close(fd)` → `clear_fd_info()` 释放内存，导致 **UAF（Use-After-Free）**。
- **风险等级**：🔴 高
- **修复方案**：
  ```c
  typedef struct {
      int active;
      int refcnt;                // 新增引用计数
      pthread_mutex_t lock;      // 新增 per-fd 锁
      int has_header;
      int is_compressed;
      struct gpuc_header hdr;
      struct gpuc_block_entry *blocks;
      off64_t cur_offset;
      off64_t phys_size;
      uint8_t *ra_buf;           // 预读缓冲区
      size_t ra_buf_size;
      uint32_t ra_seq_count;
      uint32_t ra_max_blocks;
      uint32_t last_block;
  } fd_info_t;

  // get_fd_info 返回时 refcnt++
  // close/clear 时 refcnt--，为 0 才 free(blocks) + free(info)
  ```
- **工作量**：约 30 分钟

---

### 2.2 `gpu_compress.cu`：`cudaMalloc` 未检查 + 多线程共享 Stream/Buffer

- **位置**：
  - `sglz_init():281-295` — 所有 `cudaMalloc` 无返回值检查
  - `sglz_compress_batch()` / `sglz_decompress_batch_compact_async()` — 共用 `stream[0]` 和 `g_d_batch_in[0]`
- **问题**：
  1. GPU 显存不足时 `cudaMalloc` 返回 `cudaErrorMemoryAllocation`，后续 kernel/memcpy 产生未定义行为
  2. 多线程同时提交不同 batch 到同一 `stream[0]` + `g_d_batch_in[0]`，后提交的 memcpy **覆盖前一批数据**，导致解压数据错乱
- **风险等级**：🔴 高
- **修复方案**：
  ```c
  // 1. 每次 cudaMalloc 必须检查
  cudaError_t err = cudaMalloc(&g_d_batch_in, size);
  if (err != cudaSuccess) {
      fprintf(stderr, "[SGLZ] cudaMalloc failed: %s\n", cudaGetErrorString(err));
      return -1;
  }

  // 2. 多线程资源隔离（推荐方案 A：TLS）
  static __thread cudaStream_t tls_stream = 0;
  static __thread void *tls_d_batch_in = NULL;
  static __thread void *tls_d_batch_out = NULL;
  // 每个线程首次使用时独立创建 stream + 申请内存
  ```
- **工作量**：约 40 分钟

---

### 2.3 `daemon.c`：`goto fail` 跳过 batch 缓冲区释放

- **位置**：`daemon.c:419-426`（`fail:` 标签），`daemon.c:297/342/351/364`
- **问题**：`compress_one_file()` 中 `batch_in`、`batch_out`、`batch_out_lens`、`slot_buf` 等内存在正常路径末尾释放，但 `goto fail`（如 pread 失败、write 失败、slot_len 非法）**跳过了释放代码**，造成内存泄漏。
- **风险等级**：🔴 高
- **修复方案**：统一 `cleanup` 出口
  ```c
  int compress_one_file(const char *path, ...) {
      void *batch_in = NULL, *batch_out = NULL;
      int fd_tmp = -1;
      int ret = 0;
      // ... 分配内存 ...

      if (pread64(...) < 0) { ret = -1; goto cleanup; }
      if (slot_len > ...) { ret = -1; goto cleanup; }
      // ...

  cleanup:
      free(batch_in);
      free(batch_out);
      free(batch_out_lens);
      free(slot_buf);
      if (fd_tmp >= 0) { close(fd_tmp); unlink(tmp_path); }
      if (fd_src >= 0) { close(fd_src); }
      return ret;
  }
  ```
- **工作量**：约 20 分钟

---

### 2.4 `hook.c`：`ftruncate()` 未保护压缩文件

- **位置**：`hook.c:1475-1486`
- **问题**：`write()` 已拒绝写入压缩文件（返回 `EROFS`），但 `ftruncate()` 没做同样保护，会按 `length + header_size` 物理截断压缩文件，**破坏块索引结构**，后续读取必然失败或返回错误数据。
- **风险等级**：🔴 高
- **修复方案**：
  ```c
  int ftruncate(int fd, off_t length) {
      fd_info_t *info = get_fd_info(fd);
      if (info && info->has_header) {
          if (info->is_compressed) {
              errno = EROFS;
              return -1;
          }
          length += info->hdr.header_size;
      }
      return real_ftruncate(fd, length);
  }
  ```
- **工作量**：约 5 分钟

---

## 三、P1 — 强烈建议修复

### 3.1 `gpu_compress.cu`：`g_initialized` 非原子 + kernel 同步后无错误检查

- **位置**：`gpu_compress.cu:242`（`g_initialized`），`sglz_compress_batch():436-454`
- **问题**：
  1. `g_initialized` 是普通 `int`，多线程同时首次调用可能重复创建 stream、重复 `cudaMalloc`
  2. `cudaStreamSynchronize` 后未检查 `cudaGetLastError()`，kernel 崩溃（如非法内存访问）后无感知，后续读取脏数据
- **风险等级**：🟡 中高
- **修复方案**：
  ```c
  // 方案 1：pthread_once（纯 C）
  static pthread_once_t g_init_once = PTHREAD_ONCE_INIT;
  static void do_sglz_init(void) { /* 原有 sglz_init 逻辑 */ }
  int sglz_init(void) {
      pthread_once(&g_init_once, do_sglz_init);
      return 0;
  }

  // 方案 2：每次同步后检查错误
  cudaStreamSynchronize(stream);
  cudaError_t err = cudaGetLastError();
  if (err != cudaSuccess) {
      fprintf(stderr, "[SGLZ] kernel error: %s\n", cudaGetErrorString(err));
      return -1;
  }
  ```
- **工作量**：约 20 分钟

---

### 3.2 `hook.c`：`dlsym` 失败不阻断程序

- **位置**：`hook.c:1121-1188`（`hook_init` 构造函数）
- **问题**：`dlsym(RTLD_NEXT, "read")` 等失败时仅打印 warning，程序继续运行。后续调用 `real_read(fd, buf, count)` 时 `real_read` 为 NULL，直接导致 **SIGSEGV**。
- **风险等级**：🟡 高
- **修复方案**：
  ```c
  static int g_hooks_ready = 0;

  void __attribute__((constructor(101))) hook_init(void) {
      real_read = dlsym(RTLD_NEXT, "read");
      // ... 其他 dlsym ...
      if (!real_read || !real_open || !real_pread64 || !real_close) {
          fprintf(stderr, "[HOOK] critical dlsym failed, disabling hook\n");
          return;  // g_hooks_ready 保持 0
      }
      g_hooks_ready = 1;
  }

  // 每个拦截函数入口检查
  ssize_t read(int fd, void *buf, size_t count) {
      if (!g_hooks_ready) return real_read(fd, buf, count);  // 退化到 glibc
      // ... 正常逻辑 ...
  }
  ```
- **工作量**：约 15 分钟

---

### 3.3 `hook.c`：`mmap()` 大文件一次性预解压 → OOM

- **位置**：`hook.c:1979-2036`
- **问题**：对压缩文件的 `mmap` 调用会一次性全量预解压到匿名内存。若应用 `mmap` 一个 GB 级文件，会瞬间分配并解压全部内容，**极易导致 OOM**。
- **风险等级**：🟡 中高
- **修复方案**（分阶段）：
  - **短期（比赛前）**：增加大小限制，超大文件拒绝映射
    ```c
    #define GPUC_MMAP_MAX_SIZE (256ULL * 1024 * 1024)  // 256MB
    if (length > GPUC_MMAP_MAX_SIZE) {
        errno = ENOMEM;
        return MAP_FAILED;
    }
    ```
  - **长期**：实现按需页解压（SIGSEGV handler + 页缓存），但工作量大，不适合赛前突击
- **工作量**：约 10 分钟

---

### 3.4 `file_header.h`：`gpuc_is_header()` 校验太弱

- **位置**：`file_header.h:131-134`
- **问题**：仅校验 `magic` 和 `version`，损坏文件或恶意构造的数据可能通过初检，导致后续 `num_blocks` 过大 → **整数溢出** → 越界读取或分配巨量内存。
- **风险等级**：🟡 中
- **修复方案**：
  ```c
  #define GPUC_MAX_BLOCKS (16 * 1024 * 1024ULL / GPUC_BLOCK_SIZE)  // 16GB 文件上限

  static inline int gpuc_is_header(const struct gpuc_header *h) {
      if (h->magic != GPUC_MAGIC) return 0;
      if (h->version != GPUC_VERSION) return 0;
      if (h->block_size != GPUC_BLOCK_SIZE) return 0;
      if (h->num_blocks > GPUC_MAX_BLOCKS) return 0;
      if (h->header_size < sizeof(struct gpuc_header)) return 0;
      if (h->state > GPUC_STATE_MAX) return 0;  // 非法状态
      return 1;
  }
  ```
- **工作量**：约 10 分钟

---

## 四、P2 — 工程化与测试改进

### 4.1 核心代码重复度高

| 重复逻辑 | 位置 | 建议 |
|---------|------|------|
| `read_compressed()` vs `read_compressed_at()` | `hook.c` 约 200+ 行重复 | 提取 `process_batch()` 公共函数 |
| `open/open64/creat/openat/openat64` 初始化 | `hook.c` 约 10 处重复 | 提取 `init_fd_info(fd)` |
| `dup/dup2/dup3` fd_info 深拷贝 | `hook.c` 3 处重复 | 提取 `dup_fd_info(src, dst)` |
| `lseek/lseek64` | `hook.c` 2 处重复 | 统一用 `lseek64` 实现，`lseek` 透传转换 |

**收益**：减少 bug 引入面，提高可维护性。
**工作量**：约 60 分钟

---

### 4.2 测试覆盖严重不足

当前 `benchmark_fio.sh` 仅覆盖：单线程、顺序读写、128k/1M、zero/rand。

| 缺失维度 | 风险 | 建议补充 |
|---------|------|---------|
| **多线程并发** | 无法暴露锁竞争、CUDA 资源竞争 | `JOBS_LIST="1 4 8 16"` |
| **随机 I/O** | 无法验证 read-ahead 策略 | `rw=randread/randwrite` |
| **小 block size** | 边界条件 bug 高发区 | `BS_LIST="4k 16k 64k 128k 1M 4M"` |
| **O_DIRECT** | 页缓存掩盖真实解压延迟 | `direct=1` |
| **数据完整性校验** | GPU 静默数据错误无法发现 | 每轮测试后 `md5sum` 校验 |
| **长时间压力测试** | 显存泄漏、fd 表膨胀 | `runtime=300` 长稳测试 |
| **CPU fallback 路径** | 仅人工测试验证 | `CUDA_VISIBLE_DEVICES=""` 自动化测试 |
| **sendfile / mmap / dup2** | hook 实现但未在 fio 中触发 | 编写专项 C 测试程序 |

**工作量**：约 90 分钟

---

## 五、优化执行计划（距离比赛截止 6-29）

### 第一阶段：稳定性攻坚（本周内，约 2 小时）

按以下顺序修复，每个都有独立 commit，方便回滚：

1. `daemon.c` — `goto fail` 统一 cleanup（20 min）
2. `hook.c` — `ftruncate` 压缩文件保护（5 min）
3. `hook.c` — `dlsym` 失败阻断（15 min）
4. `file_header.h` — 强化 `gpuc_is_header()`（10 min）
5. `gpu_compress.cu` — `cudaMalloc` 检查 + `cudaGetLastError()`（20 min）
6. `gpu_compress.cu` — `g_initialized` 原子化 / `pthread_once`（20 min）

### 第二阶段：并发安全（下周，约 3 小时）

7. `hook.c` — `fd_info_t` 引用计数或分段锁（30 min）
8. `gpu_compress.cu` — 多线程 stream/buffer 隔离（TLS 或线程池）（40 min）
9. `hook.c` — `mmap` 大文件限制保护（10 min）

### 第三阶段：工程化与测试（赛前一周，约 4 小时）

10. 提取公共函数，消除代码重复（60 min）
11. 扩展 `benchmark_fio.sh` 测试矩阵（90 min）
12. 编写 `sendfile`/`mmap`/`dup2` 专项测试程序（60 min）
13. 补充长稳测试 + CPU fallback 自动化测试（30 min）

---

## 六、快速修复代码片段

### 6.1 daemon.c 统一 cleanup 模板

```c
static void cleanup_compress_state(void **batch_in, void **batch_out,
                                    void **batch_out_lens, void **slot_buf,
                                    int *fd_tmp, const char *tmp_path,
                                    int *fd_src) {
    free(*batch_in); *batch_in = NULL;
    free(*batch_out); *batch_out = NULL;
    free(*batch_out_lens); *batch_out_lens = NULL;
    free(*slot_buf); *slot_buf = NULL;
    if (*fd_tmp >= 0) { close(*fd_tmp); unlink(tmp_path); *fd_tmp = -1; }
    if (*fd_src >= 0) { close(*fd_src); *fd_src = -1; }
}
```

### 6.2 hook.c 分段锁（简化版）

```c
#define FD_LOCK_BUCKETS 256
static pthread_mutex_t g_fd_locks[FD_LOCK_BUCKETS];

static inline pthread_mutex_t* get_fd_lock(int fd) {
    return &g_fd_locks[fd % FD_LOCK_BUCKETS];
}

// 初始化时遍历 init
// get_fd_info / set_fd_info 用 get_fd_lock(fd) 替代全局 g_lock
```

### 6.3 gpu_compress.cu TLS Stream

```c
static __thread cudaStream_t tls_stream = NULL;
static __thread int tls_stream_ready = 0;

static cudaStream_t get_tls_stream(void) {
    if (!tls_stream_ready) {
        cudaStreamCreate(&tls_stream);
        tls_stream_ready = 1;
    }
    return tls_stream;
}
```

---

> 以上审查基于当前 `main` 分支代码。建议每修复一项就运行 `make test` + `bash tests/benchmark_fio.sh` 验证无回归。
