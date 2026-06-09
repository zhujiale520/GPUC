/*
 * hook.c - LD_PRELOAD 拦截层
 *
 * 拦截的系统调用：
 *   open / open64 / creat / openat / openat64
 *   read / write / pread64 / pwrite64 / readv / writev
 *   lseek / lseek64
 *   dup / dup2 / dup3
 *   ftruncate / truncate
 *   close
 *   __fxstat / __fxstat64  (fstat)
 *
 * 核心逻辑：
 *   - open 新文件时写入 RAW header
 *   - write 直接透传（不压缩），维护逻辑偏移
 *   - read 对已压缩文件调用 GPU 解压
 *   - pread64 对压缩文件走 GPU 解压路径（支持 cp/dd 等工具）
 *   - dup2/dup3 复制 fd 时同步复制 fd_info（支持 dd 等工具）
 *   - ftruncate 对 RAW 文件调整截断长度（保留 header）
 *   - lseek 在逻辑偏移和物理偏移之间转换
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sendfile.h>
#include <sys/stat.h>
#include <sys/uio.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <stdint.h>
#include <errno.h>
#include <stdarg.h>

#include "file_header.h"
#include "gpu_compress_api.h"

/* ============================================================
 *  GPU 函数弱定义 stub（供纯 CPU 编译 libcpuhook.so 使用）
 *  当链接 gpu_compress.cu 时，强定义会覆盖这些弱定义。
 * ============================================================ */
__attribute__((weak)) int  gpu_compress_init(void) { return -1; }
__attribute__((weak)) void gpu_compress_fini(void) { }
__attribute__((weak)) int  gpu_decompress_128k(const uint8_t *in, size_t in_len,
                                                uint8_t *out, size_t out_len) {
    (void)in; (void)in_len; (void)out; (void)out_len;
    return -1;
}
__attribute__((weak)) int  gpu_decompress_batch(int n,
                                                const uint8_t **in_bufs, const size_t *in_lens,
                                                uint8_t **out_bufs, const size_t *out_lens) {
    (void)n; (void)in_bufs; (void)in_lens; (void)out_bufs; (void)out_lens;
    return -1;
}
__attribute__((weak)) int  gpu_decompress_batch_compact(int n,
                                                         const uint8_t *in_buf, size_t in_total_len,
                                                         const int *chunk_offsets,
                                                         uint8_t **out_bufs, const size_t *out_lens) {
    (void)n; (void)in_buf; (void)in_total_len; (void)chunk_offsets;
    (void)out_bufs; (void)out_lens;
    return -1;
}
__attribute__((weak)) int  gpu_decompress_batch_compact_async(int n,
                                                               const uint8_t *in_buf, size_t in_total_len,
                                                               const int *chunk_offsets,
                                                               const size_t *out_lens,
                                                               int stream_id) {
    (void)n; (void)in_buf; (void)in_total_len; (void)chunk_offsets;
    (void)out_lens; (void)stream_id;
    return -1;
}
__attribute__((weak)) int  gpu_decompress_batch_compact_wait(int stream_id, int n,
                                                              uint8_t **out_bufs, const size_t *out_lens) {
    (void)stream_id; (void)n; (void)out_bufs; (void)out_lens;
    return -1;
}
__attribute__((weak)) int  gpu_tls_alloc_pinned(void **ptr, size_t size) {
    (void)ptr; (void)size; return -1;
}
__attribute__((weak)) void gpu_tls_free_pinned(void *ptr) {
    (void)ptr;
}

/* ============================================================
 *  TLS 缓冲区分配宏（GPU build 用 pinned memory，CPU build 用 malloc）
 * ============================================================ */
#ifdef CPU_ONLY_BUILD
#define tls_alloc(buf, sz)  do { buf = (uint8_t *)malloc(sz); } while(0)
#define tls_free(buf)       do { free(buf); buf = NULL; } while(0)
#else
#define tls_alloc(buf, sz)  \
    do { \
        if (gpu_tls_alloc_pinned((void **)&(buf), (sz)) != 0) { \
            buf = (uint8_t *)malloc(sz); \
        } \
    } while(0)
#define tls_free(buf)       \
    do { \
        if (buf) { gpu_tls_free_pinned(buf); buf = NULL; } \
    } while(0)
#endif

/* ============================================================
 *  原始系统调用符号
 * ============================================================ */
static ssize_t (*real_read)(int, void *, size_t);
static volatile ssize_t (*real_write)(int, const void *, size_t);
static int     (*real_open)(const char *, int, ...);
static int     (*real_open64)(const char *, int, ...);
static int     (*real_creat)(const char *, mode_t);
static off_t   (*real_lseek)(int, off_t, int);
static off64_t (*real_lseek64)(int, off64_t, int);
static volatile int     (*real_close)(int);
static ssize_t (*real_pread64)(int, void *, size_t, off64_t);
static ssize_t (*real_pwrite64)(int, const void *, size_t, off64_t);
static ssize_t (*real_readv)(int, const struct iovec *, int);
static ssize_t (*real_writev)(int, const struct iovec *, int);
static int     (*real_openat)(int, const char *, int, ...);
static int     (*real_openat64)(int, const char *, int, ...);
static int     (*real_fxstat)(int, int, struct stat *);
static int     (*real_fxstat64)(int, int, struct stat64 *);
static volatile int     (*real_xstat)(int, const char *, struct stat *);
static volatile int     (*real_xstat64)(int, const char *, struct stat64 *);
static volatile int     (*real_lxstat)(int, const char *, struct stat *);
static volatile int     (*real_lxstat64)(int, const char *, struct stat64 *);
static int     (*real_ftruncate)(int, off_t);
static int     (*real_truncate)(const char *, off_t);
static int     (*real_dup)(int);
static int     (*real_dup2)(int, int);
static int     (*real_dup3)(int, int, int);
static ssize_t (*real_sendfile)(int, int, off_t *, size_t);
static void *(*real_mmap)(void *, size_t, int, int, int, off_t);
static int (*real_munmap)(void *, size_t);
static int (*real_msync)(void *, size_t, int);
static pthread_once_t g_backend_init_once = PTHREAD_ONCE_INIT;
static int g_hooks_disabled = 1;  /* 默认禁用，hook_init 完成后启用 */

/* -------- Backend 函数指针（支持 CPU/GPU 运行时切换）-------- */
static int  (*g_backend_compress_init)(void);
static void (*g_backend_compress_fini)(void);
static int  (*g_backend_decompress_128k)(const uint8_t *, size_t, uint8_t *, size_t);
static int  (*g_backend_decompress_batch)(int, const uint8_t **, const size_t *, uint8_t **, const size_t *);
static int  (*g_backend_decompress_batch_compact)(int, const uint8_t *, size_t, const int *, uint8_t **, const size_t *);
static int  (*g_backend_decompress_batch_compact_async)(int, const uint8_t *, size_t, const int *, const size_t *, int);
static int  (*g_backend_decompress_batch_compact_wait)(int, int, uint8_t **, const size_t *);
static const char *g_backend_name = "gpu";
static int g_backend_initialized = 0;

static void do_backend_init(void) {
    if (!g_backend_initialized && g_backend_compress_init) {
        int ret = g_backend_compress_init();
        if (ret == 0) {
            g_backend_initialized = 1;
        } else if (g_backend_compress_init == gpu_compress_init) {
            /* GPU init failed in lazy init, fallback to CPU */
            fprintf(stderr, "[HOOK] GPU lazy init failed (ret=%d), fallback to CPU backend\n", ret);
            g_backend_name = "cpu-fallback";
            g_backend_compress_init = cpu_compress_init;
            g_backend_compress_fini = cpu_compress_fini;
            g_backend_decompress_128k = cpu_decompress_128k;
            g_backend_decompress_batch = cpu_decompress_batch;
            g_backend_decompress_batch_compact = cpu_decompress_batch_compact;
            g_backend_decompress_batch_compact_async = cpu_decompress_batch_compact_async;
            g_backend_decompress_batch_compact_wait = cpu_decompress_batch_compact_wait;
            if (g_backend_compress_init() == 0) {
                g_backend_initialized = 1;
            }
        }
    }
}

static void ensure_backend_init(void) {
    pthread_once(&g_backend_init_once, do_backend_init);
}

/* ============================================================
 *  辅助：判断 fd 是否为普通文件（只 hook 普通文件）
 * ============================================================ */
static int is_regular_file(int fd) {
    struct stat64 st;
    if (fstat64(fd, &st) != 0) return 0;
    return S_ISREG(st.st_mode);
}

/* ============================================================
 *  fd 管理表
 * ============================================================ */
#define MAX_FD 65536

typedef struct {
    int active;
    int has_header;
    int is_compressed;
    struct gpuc_header hdr;
    struct gpuc_block_entry *blocks;
    off64_t cur_offset;   /* 逻辑偏移（用户视角） */
    off64_t phys_size;    /* 物理文件大小 */
    /* read-ahead cache */
    uint8_t *ra_buf;
    off64_t ra_start_offset;
    size_t ra_valid_len;
    int ra_active;
    /* 自适应预读：顺序检测 */
    uint32_t last_read_block; /* 上次读取的结束 block */
    int seq_count;            /* 连续顺序读取计数 */
    int ra_max_blocks;        /* 当前预读窗口大小 */
} fd_info_t;

static fd_info_t *g_fd_table[MAX_FD];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static fd_info_t* get_fd_info(int fd) {
    if (fd < 0 || fd >= MAX_FD) return NULL;
    pthread_mutex_lock(&g_lock);
    fd_info_t *info = g_fd_table[fd];
    pthread_mutex_unlock(&g_lock);
    return info;
}

static void set_fd_info(int fd, fd_info_t *info) {
    if (fd < 0 || fd >= MAX_FD) return;
    pthread_mutex_lock(&g_lock);
    if (g_fd_table[fd]) {
        free(g_fd_table[fd]->blocks);
        free(g_fd_table[fd]);
    }
    g_fd_table[fd] = info;
    pthread_mutex_unlock(&g_lock);
}

static void clear_fd_info(int fd) {
    if (fd < 0 || fd >= MAX_FD) return;
    pthread_mutex_lock(&g_lock);
    if (g_fd_table[fd]) {
        free(g_fd_table[fd]->blocks);
        free(g_fd_table[fd]->ra_buf);
        free(g_fd_table[fd]);
        g_fd_table[fd] = NULL;
    }
    pthread_mutex_unlock(&g_lock);
}

/* ============================================================
 *  辅助函数
 * ============================================================ */

static off64_t get_phys_size(int fd) {
    struct stat64 st;
    if (fstat64(fd, &st) < 0) return 0;
    return st.st_size;
}

static int read_header(int fd, fd_info_t *info) {
    int saved_errno = errno;
    struct gpuc_header hdr;
    ssize_t n = real_pread64(fd, &hdr, sizeof(hdr), 0);
    if (n != (ssize_t)sizeof(hdr)) {
        errno = saved_errno;
        return -1;
    }
    if (!gpuc_is_header(&hdr)) {
        errno = saved_errno;
        return -1;
    }

    info->has_header = 1;
    info->hdr = hdr;
    info->is_compressed = (hdr.state == GPUC_STATE_COMPRESSED || hdr.state == GPUC_STATE_INLINE);

    if (hdr.state == GPUC_STATE_COMPRESSED && hdr.num_blocks > 0) {
        /* 根据 header_size 推断 entry 大小，兼容旧格式（16字节）和新格式（24字节） */
        size_t entry_size = 0;
        if (hdr.header_size > sizeof(hdr) && hdr.num_blocks > 0) {
            entry_size = (hdr.header_size - sizeof(hdr)) / hdr.num_blocks;
        }
        if (entry_size != 16 && entry_size != 24) {
            entry_size = sizeof(struct gpuc_block_entry);  /* 默认新格式 */
        }
        size_t blocks_data_size = hdr.num_blocks * entry_size;
        size_t blocks_alloc_size = hdr.num_blocks * sizeof(struct gpuc_block_entry);
        info->blocks = (struct gpuc_block_entry *)calloc(1, blocks_alloc_size);
        if (!info->blocks) {
            errno = saved_errno;
            return -1;
        }
        uint8_t *block_buf = (uint8_t *)malloc(blocks_data_size);
        if (!block_buf) {
            free(info->blocks);
            info->blocks = NULL;
            errno = saved_errno;
            return -1;
        }
        n = real_pread64(fd, block_buf, blocks_data_size, (off64_t)sizeof(hdr));
        if ((size_t)n != blocks_data_size) {
            free(block_buf);
            free(info->blocks);
            info->blocks = NULL;
            errno = saved_errno;
            return -1;
        }
        for (uint32_t i = 0; i < hdr.num_blocks; i++) {
            uint8_t *src = block_buf + i * entry_size;
            struct gpuc_block_entry *dst = &info->blocks[i];
            dst->orig_len = *(uint32_t *)(src + 0);
            dst->comp_len = *(uint32_t *)(src + 4);
            dst->offset   = *(uint64_t *)(src + 8);
            if (entry_size >= 24) {
                dst->crc32 = *(uint32_t *)(src + 16);
            }
        }
        free(block_buf);
    }
    errno = saved_errno;
    return 0;
}

static int write_raw_header(int fd, fd_info_t *info) {
    struct gpuc_header hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = GPUC_MAGIC;
    hdr.version = GPUC_VERSION;
    hdr.block_size = GPUC_BLOCK_SIZE;
    hdr.state = GPUC_STATE_RAW;
    hdr.comp_algo = GPUC_ALGO_SGLZ;
    hdr.header_size = sizeof(hdr);
    hdr.mtime = 0;
    hdr.ctime = 0;

    info->hdr = hdr;
    info->has_header = 1;
    info->is_compressed = 0;

    ssize_t n = real_write(fd, &hdr, sizeof(hdr));
    if (n != (ssize_t)sizeof(hdr)) return -1;
    return 0;
}

static off64_t get_logical_size(fd_info_t *info) {
    if (!info->has_header) return info->phys_size;
    if (info->is_compressed) return (off64_t)info->hdr.orig_size;
    return info->phys_size - (off64_t)info->hdr.header_size;
}

/* ============================================================
 *  线程局部存储：压缩读重用缓冲区（避免每块 malloc/free）
 * ============================================================ */

static __thread uint8_t *g_tls_comp_buf = NULL;
static __thread uint8_t *g_tls_decomp_buf = NULL;
static __thread uint8_t *g_tls_slot_buf = NULL;

static int ensure_tls_buffers(void) {
    if (!g_tls_comp_buf) {
        tls_alloc(g_tls_comp_buf, GC_NCHUNKS * GC_SLOT_SIZE);
        if (!g_tls_comp_buf) return -1;
    }
    if (!g_tls_decomp_buf) {
        tls_alloc(g_tls_decomp_buf, GPUC_BLOCK_SIZE);
        if (!g_tls_decomp_buf) return -1;
    }
    if (!g_tls_slot_buf) {
        tls_alloc(g_tls_slot_buf, GC_NCHUNKS * GC_SLOT_SIZE);
        if (!g_tls_slot_buf) return -1;
    }
    return 0;
}

/* ============================================================
 *  批量解压 TLS 缓冲区（支持一次解压多个 128KB 块）
 * ============================================================ */

#define MAX_BATCH_BLOCKS 16

static __thread uint8_t *g_tls_batch_comp_bufs = NULL;
static __thread uint8_t *g_tls_batch_decomp_bufs = NULL;
static __thread uint8_t **g_tls_batch_in_ptrs = NULL;
static __thread uint8_t **g_tls_batch_out_ptrs = NULL;
static __thread size_t *g_tls_batch_in_lens = NULL;
static __thread size_t *g_tls_batch_out_lens = NULL;

static int ensure_batch_tls_buffers(void) {
    if (!g_tls_batch_comp_bufs) {
        tls_alloc(g_tls_batch_comp_bufs, MAX_BATCH_BLOCKS * GC_NCHUNKS * GC_SLOT_SIZE);
        if (!g_tls_batch_comp_bufs) return -1;
    }
    if (!g_tls_batch_decomp_bufs) {
        tls_alloc(g_tls_batch_decomp_bufs, MAX_BATCH_BLOCKS * GPUC_BLOCK_SIZE);
        if (!g_tls_batch_decomp_bufs) return -1;
    }
    if (!g_tls_batch_in_ptrs) {
        g_tls_batch_in_ptrs = (uint8_t **)malloc(MAX_BATCH_BLOCKS * sizeof(uint8_t *));
        if (!g_tls_batch_in_ptrs) return -1;
    }
    if (!g_tls_batch_out_ptrs) {
        g_tls_batch_out_ptrs = (uint8_t **)malloc(MAX_BATCH_BLOCKS * sizeof(uint8_t *));
        if (!g_tls_batch_out_ptrs) return -1;
    }
    if (!g_tls_batch_in_lens) {
        g_tls_batch_in_lens = (size_t *)malloc(MAX_BATCH_BLOCKS * sizeof(size_t));
        if (!g_tls_batch_in_lens) return -1;
    }
    if (!g_tls_batch_out_lens) {
        g_tls_batch_out_lens = (size_t *)malloc(MAX_BATCH_BLOCKS * sizeof(size_t));
        if (!g_tls_batch_out_lens) return -1;
    }
    return 0;
}

/* ============================================================
 *  双缓冲流水线 TLS（overlap I/O with GPU compute）
 * ============================================================ */

#define NUM_PIPELINES 2

static __thread uint8_t *g_tls_pipe_comp_bufs[NUM_PIPELINES] = {NULL, NULL};
static __thread uint8_t *g_tls_pipe_decomp_bufs[NUM_PIPELINES] = {NULL, NULL};
static __thread uint8_t *g_tls_pipe_out_ptrs[NUM_PIPELINES][MAX_BATCH_BLOCKS];
static __thread size_t g_tls_pipe_out_lens[NUM_PIPELINES][MAX_BATCH_BLOCKS];
static __thread int g_tls_pipe_chunk_offsets[NUM_PIPELINES][MAX_BATCH_BLOCKS * GC_NCHUNKS];
static __thread int g_tls_pipe_total_compact_len[NUM_PIPELINES];
static __thread int g_tls_pipe_n_compressed[NUM_PIPELINES];
static __thread int g_tls_pipe_nblocks[NUM_PIPELINES];
static __thread int g_tls_pipe_user_nblocks[NUM_PIPELINES];
static __thread uint32_t g_tls_pipe_first_block[NUM_PIPELINES];
static __thread off64_t g_tls_pipe_first_block_off[NUM_PIPELINES];

/* io_uring 批量读取的独立 raw buffer（避免与 compact buffer 重叠） */
static __thread uint8_t *g_tls_iouring_raw_bufs[NUM_PIPELINES] = {NULL, NULL};

static int ensure_pipe_buffers(void) {
    for (int p = 0; p < NUM_PIPELINES; p++) {
        if (!g_tls_pipe_comp_bufs[p]) {
            tls_alloc(g_tls_pipe_comp_bufs[p], MAX_BATCH_BLOCKS * GC_NCHUNKS * GC_SLOT_SIZE);
            if (!g_tls_pipe_comp_bufs[p]) return -1;
        }
        if (!g_tls_pipe_decomp_bufs[p]) {
            tls_alloc(g_tls_pipe_decomp_bufs[p], MAX_BATCH_BLOCKS * GPUC_BLOCK_SIZE);
            if (!g_tls_pipe_decomp_bufs[p]) return -1;
        }
        if (!g_tls_iouring_raw_bufs[p]) {
            tls_alloc(g_tls_iouring_raw_bufs[p], MAX_BATCH_BLOCKS * GPUC_BLOCK_SIZE);
            if (!g_tls_iouring_raw_bufs[p]) return -1;
        }
    }
    return 0;
}

/* 验证单个 batch 内所有 block 的 CRC32 */
static int verify_batch_crc(fd_info_t *info, int pipe_id, uint32_t first_block, int nblocks) {
    for (int i = 0; i < nblocks; i++) {
        uint32_t bid = first_block + i;
        struct gpuc_block_entry *be = &info->blocks[bid];
        if (be->crc32 == 0) continue;  /* 旧格式或未计算，跳过 */
        uint8_t *data = g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE;
        uint32_t computed = gpuc_crc32(data, be->orig_len);
        if (computed != be->crc32) {
            fprintf(stderr, "[HOOK] CRC32 mismatch at block %u: expected %08x, got %08x\n",
                    bid, be->crc32, computed);
            return -1;
        }
    }
    return 0;
}


/* ============================================================
 *  io_uring 轻量级封装（批量异步 pread，减少 syscall 开销）
 * ============================================================ */

#include <linux/io_uring.h>
#include <sys/mman.h>

#ifndef IORING_OP_READ
#define IORING_OP_READ 22
#endif

struct gpuc_iouring {
    int ring_fd;
    struct io_uring_params params;
    void *sq_ring;
    void *cq_ring;
    struct io_uring_sqe *sqes;
    unsigned sq_mask;
    unsigned cq_mask;
    unsigned *sq_array;
    unsigned *sq_head;
    unsigned *sq_tail;
    unsigned *cq_head;
    unsigned *cq_tail;
    struct io_uring_cqe *cqes;
    int initialized;
};

static struct gpuc_iouring g_iouring = { -1, {0}, NULL, NULL, NULL, 0, 0, NULL, NULL, NULL, NULL, NULL, NULL, 0 };

static int gpuc_iouring_init(unsigned int entries) {
    if (g_iouring.initialized) return 0;
    memset(&g_iouring.params, 0, sizeof(g_iouring.params));
    g_iouring.ring_fd = syscall(__NR_io_uring_setup, entries, &g_iouring.params);
    if (g_iouring.ring_fd < 0) return -1;

    size_t sq_ring_size = g_iouring.params.sq_off.array + g_iouring.params.sq_entries * sizeof(unsigned);
    size_t cq_ring_size = g_iouring.params.cq_off.cqes + g_iouring.params.cq_entries * sizeof(struct io_uring_cqe);
    size_t sqes_size = g_iouring.params.sq_entries * sizeof(struct io_uring_sqe);

    g_iouring.sq_ring = mmap(NULL, sq_ring_size, PROT_READ | PROT_WRITE,
                              MAP_SHARED | MAP_POPULATE, g_iouring.ring_fd, IORING_OFF_SQ_RING);
    g_iouring.cq_ring = mmap(NULL, cq_ring_size, PROT_READ | PROT_WRITE,
                              MAP_SHARED | MAP_POPULATE, g_iouring.ring_fd, IORING_OFF_CQ_RING);
    g_iouring.sqes = mmap(NULL, sqes_size, PROT_READ | PROT_WRITE,
                          MAP_SHARED | MAP_POPULATE, g_iouring.ring_fd, IORING_OFF_SQES);

    if (g_iouring.sq_ring == MAP_FAILED || g_iouring.cq_ring == MAP_FAILED || g_iouring.sqes == MAP_FAILED) {
        if (g_iouring.sq_ring != MAP_FAILED) munmap(g_iouring.sq_ring, sq_ring_size);
        if (g_iouring.cq_ring != MAP_FAILED) munmap(g_iouring.cq_ring, cq_ring_size);
        if (g_iouring.sqes != MAP_FAILED) munmap(g_iouring.sqes, sqes_size);
        close(g_iouring.ring_fd);
        g_iouring.ring_fd = -1;
        return -1;
    }

    g_iouring.sq_head = (unsigned *)((char *)g_iouring.sq_ring + g_iouring.params.sq_off.head);
    g_iouring.sq_tail = (unsigned *)((char *)g_iouring.sq_ring + g_iouring.params.sq_off.tail);
    g_iouring.sq_mask = *(unsigned *)((char *)g_iouring.sq_ring + g_iouring.params.sq_off.ring_mask);
    g_iouring.sq_array = (unsigned *)((char *)g_iouring.sq_ring + g_iouring.params.sq_off.array);

    g_iouring.cq_head = (unsigned *)((char *)g_iouring.cq_ring + g_iouring.params.cq_off.head);
    g_iouring.cq_tail = (unsigned *)((char *)g_iouring.cq_ring + g_iouring.params.cq_off.tail);
    g_iouring.cq_mask = *(unsigned *)((char *)g_iouring.cq_ring + g_iouring.params.cq_off.ring_mask);
    g_iouring.cqes = (struct io_uring_cqe *)((char *)g_iouring.cq_ring + g_iouring.params.cq_off.cqes);

    g_iouring.initialized = 1;
    return 0;
}

static void gpuc_iouring_fini(void) {
    if (!g_iouring.initialized) return;
    size_t sq_ring_size = g_iouring.params.sq_off.array + g_iouring.params.sq_entries * sizeof(unsigned);
    size_t cq_ring_size = g_iouring.params.cq_off.cqes + g_iouring.params.cq_entries * sizeof(struct io_uring_cqe);
    size_t sqes_size = g_iouring.params.sq_entries * sizeof(struct io_uring_sqe);
    if (g_iouring.sq_ring != MAP_FAILED && g_iouring.sq_ring != NULL) munmap(g_iouring.sq_ring, sq_ring_size);
    if (g_iouring.cq_ring != MAP_FAILED && g_iouring.cq_ring != NULL) munmap(g_iouring.cq_ring, cq_ring_size);
    if (g_iouring.sqes != MAP_FAILED && g_iouring.sqes != NULL) munmap(g_iouring.sqes, sqes_size);
    if (g_iouring.ring_fd >= 0) close(g_iouring.ring_fd);
    memset(&g_iouring, 0, sizeof(g_iouring));
    g_iouring.ring_fd = -1;
}

static int gpuc_iouring_submit_pread(int fd, void *buf, size_t len, off64_t off) {
    if (!g_iouring.initialized) return -1;
    unsigned tail = *g_iouring.sq_tail;
    unsigned index = tail & g_iouring.sq_mask;
    struct io_uring_sqe *sqe = &g_iouring.sqes[index];
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = IORING_OP_READ;
    sqe->fd = fd;
    sqe->off = (uint64_t)off;
    sqe->addr = (uint64_t)(uintptr_t)buf;
    sqe->len = (__u32)len;
    sqe->user_data = (uint64_t)(uintptr_t)buf;
    g_iouring.sq_array[index] = index;
    *g_iouring.sq_tail = tail + 1;
    return 0;
}

static int gpuc_iouring_enter_wait(int to_submit, int min_complete) {
    if (!g_iouring.initialized) return -1;
    return syscall(__NR_io_uring_enter, g_iouring.ring_fd, (unsigned)to_submit,
                   (unsigned)min_complete, IORING_ENTER_GETEVENTS, NULL, 0);
}

static int gpuc_iouring_wait_all(int n, int *results) {
    if (!g_iouring.initialized) return -1;
    int completed = 0;
    while (completed < n) {
        unsigned head = *g_iouring.cq_head;
        unsigned tail = *g_iouring.cq_tail;
        while (head != tail && completed < n) {
            struct io_uring_cqe *cqe = &g_iouring.cqes[head & g_iouring.cq_mask];
            if (results) results[completed] = cqe->res;
            head++;
            completed++;
        }
        *g_iouring.cq_head = head;
        if (completed < n) {
            int ret = gpuc_iouring_enter_wait(0, n - completed);
            if (ret < 0) return ret;
        }
    }
    return 0;
}

/* ============================================================
 *  已压缩文件的 read 路径（GPU 解压）
 * ============================================================ */

static ssize_t read_compressed(int fd, fd_info_t *info, void *buf, size_t count) {
    /* ---- 小文件内联：直接从 header 后读取原始数据（无需 GPU 解压） ---- */
    if (info->hdr.state == GPUC_STATE_INLINE) {
        off64_t log_size = get_logical_size(info);
        if (info->cur_offset >= log_size) return 0;
        if (info->cur_offset + (off64_t)count > log_size)
            count = (size_t)(log_size - info->cur_offset);
        off64_t phys_off = info->cur_offset + (off64_t)sizeof(info->hdr);
        ssize_t ret = real_pread64(fd, buf, count, phys_off);
        if (ret > 0) info->cur_offset += ret;
        return ret;
    }

    ensure_backend_init();
    if (ensure_tls_buffers() != 0 || ensure_batch_tls_buffers() != 0 || ensure_pipe_buffers() != 0) {
        errno = ENOMEM;
        return -1;
    }
    off64_t start = info->cur_offset;
    off64_t log_size = get_logical_size(info);
    if (start >= log_size) return 0;
    if (start + (off64_t)count > log_size)
        count = (size_t)(log_size - start);

    uint8_t *out_ptr = (uint8_t *)buf;
    size_t total_read = 0;

    /* ---- 阶段 0: 检查预读缓存命中 ---- */
    if (info->ra_active && start >= info->ra_start_offset) {
        off64_t ra_end = info->ra_start_offset + (off64_t)info->ra_valid_len;
        if (start < ra_end) {
            size_t ra_off = (size_t)(start - info->ra_start_offset);
            size_t to_copy = (size_t)(ra_end - start);
            if (to_copy > count) to_copy = count;
            memcpy(out_ptr, info->ra_buf + ra_off, to_copy);
            out_ptr += to_copy;
            start += to_copy;
            count -= to_copy;
            total_read += to_copy;
            if (count == 0) {
                info->cur_offset = start;
                return (ssize_t)total_read;
            }
        }
    }

    /* ---- 自适应 read-ahead：检测顺序/随机访问 ---- */
    uint32_t first_block = (uint32_t)(start / GPUC_BLOCK_SIZE);
    if (info->last_read_block > 0 &&
        (first_block == info->last_read_block || first_block == info->last_read_block + 1)) {
        info->seq_count++;
        if (info->seq_count >= 8) info->ra_max_blocks = MAX_BATCH_BLOCKS;
        else if (info->seq_count >= 4) info->ra_max_blocks = 8;
        else if (info->seq_count >= 2) info->ra_max_blocks = 4;
        else info->ra_max_blocks = 0;
    } else {
        info->seq_count = 0;
        info->ra_max_blocks = 0;
    }

    int pipe_id = 0;
    int has_submitted = 0;
    off64_t orig_start = start;
    size_t orig_count = count;

    while (count > 0) {
        first_block = (uint32_t)(start / GPUC_BLOCK_SIZE);
        off64_t first_block_off = start % GPUC_BLOCK_SIZE;
        if (first_block >= info->hdr.num_blocks) break;

        uint32_t last_block = (uint32_t)((start + count - 1) / GPUC_BLOCK_SIZE);
        if (last_block >= info->hdr.num_blocks) last_block = info->hdr.num_blocks - 1;
        int user_nblocks = (int)(last_block - first_block + 1);
        if (user_nblocks > MAX_BATCH_BLOCKS) user_nblocks = MAX_BATCH_BLOCKS;

        /* 自适应 over-read */
        int decompress_nblocks = user_nblocks;
        if (decompress_nblocks < info->ra_max_blocks) {
            uint32_t over_last = first_block + info->ra_max_blocks - 1;
            if (over_last >= info->hdr.num_blocks) over_last = info->hdr.num_blocks - 1;
            decompress_nblocks = (int)(over_last - first_block + 1);
        }

        /* 如果有已提交的 batch，先消费它 */
        if (has_submitted) {
            int prev = 1 - pipe_id;

            if (g_tls_pipe_n_compressed[prev] > 0) {
                g_backend_decompress_batch_compact_wait(prev,
                    g_tls_pipe_n_compressed[prev],
                    g_tls_pipe_out_ptrs[prev],
                    g_tls_pipe_out_lens[prev]);
            }

            if (verify_batch_crc(info, prev, g_tls_pipe_first_block[prev],
                                 g_tls_pipe_nblocks[prev]) != 0) {
                return (total_read > 0) ? (ssize_t)total_read : -1;
            }

            for (int i = 0; i < g_tls_pipe_user_nblocks[prev] && count > 0; i++) {
                uint32_t bid = g_tls_pipe_first_block[prev] + i;
                off64_t block_off = (bid == g_tls_pipe_first_block[prev])
                                    ? g_tls_pipe_first_block_off[prev] : 0;
                size_t to_copy = GPUC_BLOCK_SIZE - (size_t)block_off;
                if (to_copy > count) to_copy = count;
                memcpy(out_ptr, g_tls_pipe_decomp_bufs[prev] + i * GPUC_BLOCK_SIZE + block_off, to_copy);
                out_ptr += to_copy;
                start += to_copy;
                count -= to_copy;
                total_read += to_copy;
            }

            if (g_tls_pipe_nblocks[prev] > g_tls_pipe_user_nblocks[prev] && count == 0) {
                if (!info->ra_buf) {
                    info->ra_buf = (uint8_t *)malloc(MAX_BATCH_BLOCKS * GPUC_BLOCK_SIZE);
                }
                if (info->ra_buf) {
                    size_t ra_len = 0;
                    for (int i = g_tls_pipe_user_nblocks[prev]; i < g_tls_pipe_nblocks[prev]; i++) {
                        uint32_t bid = g_tls_pipe_first_block[prev] + i;
                        size_t block_data = info->blocks[bid].orig_len;
                        memcpy(info->ra_buf + ra_len,
                               g_tls_pipe_decomp_bufs[prev] + i * GPUC_BLOCK_SIZE, block_data);
                        ra_len += block_data;
                    }
                    info->ra_start_offset = start;
                    info->ra_valid_len = ra_len;
                    info->ra_active = 1;
                }
            }

            has_submitted = 0;
            if (count == 0) break;
        }

        /* 准备当前 batch（CPU pread / io_uring，与上一个 batch 的 GPU 解压重叠） */
        g_tls_pipe_first_block[pipe_id] = first_block;
        g_tls_pipe_first_block_off[pipe_id] = first_block_off;
        g_tls_pipe_user_nblocks[pipe_id] = user_nblocks;
        g_tls_pipe_nblocks[pipe_id] = decompress_nblocks;
        g_tls_pipe_n_compressed[pipe_id] = 0;
        g_tls_pipe_total_compact_len[pipe_id] = 0;

        int use_iouring = g_iouring.initialized;
        if (use_iouring) {
            for (int i = 0; i < decompress_nblocks; i++) {
                uint32_t bid = first_block + i;
                struct gpuc_block_entry *be = &info->blocks[bid];
                uint8_t *read_buf = (be->comp_len == be->orig_len)
                    ? g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE
                    : g_tls_iouring_raw_bufs[pipe_id] + i * GPUC_BLOCK_SIZE;
                gpuc_iouring_submit_pread(fd, read_buf, be->comp_len, (off64_t)be->offset);
            }
            if (gpuc_iouring_enter_wait(decompress_nblocks, 0) < 0) {
                use_iouring = 0;  /* 提交失败，fallback */
            } else {
                int iouring_results[MAX_BATCH_BLOCKS];
                if (gpuc_iouring_wait_all(decompress_nblocks, iouring_results) < 0) {
                    use_iouring = 0;
                } else {
                    for (int i = 0; i < decompress_nblocks; i++) {
                        uint32_t bid = first_block + i;
                        struct gpuc_block_entry *be = &info->blocks[bid];
                        if (iouring_results[i] < 0 || (size_t)iouring_results[i] != be->comp_len) {
                            fprintf(stderr, "[HOOK] io_uring read failed at block %u: %d\n",
                                    bid, iouring_results[i]);
                            use_iouring = 0;
                            break;
                        }
                    }
                }
            }
        }

        for (int i = 0; i < decompress_nblocks; i++) {
            uint32_t bid = first_block + i;
            struct gpuc_block_entry *be = &info->blocks[bid];

            if (be->comp_len == be->orig_len) {
                if (!use_iouring) {
                    ssize_t nr = real_pread64(fd, g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE,
                                              be->comp_len, (off64_t)be->offset);
                    if (nr != (ssize_t)be->comp_len) {
                        return (total_read > 0) ? (ssize_t)total_read : -1;
                    }
                }
                continue;
            }

            uint8_t *raw_buf = use_iouring
                ? g_tls_iouring_raw_bufs[pipe_id] + i * GPUC_BLOCK_SIZE
                : g_tls_comp_buf;

            if (!use_iouring) {
                ssize_t nr = real_pread64(fd, raw_buf, be->comp_len, (off64_t)be->offset);
                if (nr != (ssize_t)be->comp_len) {
                    return (total_read > 0) ? (ssize_t)total_read : -1;
                }
            }

            int file_pos = 0;
            for (int j = 0; j < GC_NCHUNKS && file_pos < (int)be->comp_len; j++) {
                g_tls_pipe_chunk_offsets[pipe_id][g_tls_pipe_n_compressed[pipe_id] * GC_NCHUNKS + j]
                    = g_tls_pipe_total_compact_len[pipe_id] + file_pos;
                uint16_t chunk_len = *(uint16_t *)(raw_buf + file_pos);
                if (chunk_len == 0xFFFF) chunk_len = 2 + GC_CHUNK_SIZE;
                file_pos += chunk_len;
            }
            memcpy(g_tls_pipe_comp_bufs[pipe_id] + g_tls_pipe_total_compact_len[pipe_id],
                   raw_buf, be->comp_len);
            g_tls_pipe_total_compact_len[pipe_id] += be->comp_len;
            g_tls_pipe_out_ptrs[pipe_id][g_tls_pipe_n_compressed[pipe_id]]
                = g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE;
            g_tls_pipe_out_lens[pipe_id][g_tls_pipe_n_compressed[pipe_id]] = be->orig_len;
            g_tls_pipe_n_compressed[pipe_id]++;
        }

        /* 提交当前 batch GPU async */
        if (g_tls_pipe_n_compressed[pipe_id] > 0) {
            if (g_backend_decompress_batch_compact_async) {
                g_backend_decompress_batch_compact_async(
                    g_tls_pipe_n_compressed[pipe_id],
                    g_tls_pipe_comp_bufs[pipe_id], g_tls_pipe_total_compact_len[pipe_id],
                    g_tls_pipe_chunk_offsets[pipe_id],
                    g_tls_pipe_out_lens[pipe_id],
                    pipe_id);
            } else if (g_backend_decompress_batch_compact) {
                /* async 不可用，fallback 到同步 */
                g_backend_decompress_batch_compact(
                    g_tls_pipe_n_compressed[pipe_id],
                    g_tls_pipe_comp_bufs[pipe_id], g_tls_pipe_total_compact_len[pipe_id],
                    g_tls_pipe_chunk_offsets[pipe_id],
                    g_tls_pipe_out_ptrs[pipe_id], g_tls_pipe_out_lens[pipe_id]);
            }
        }

        has_submitted = 1;
        pipe_id = 1 - pipe_id;
    }

    /* 处理最后一个已提交但未消费的 batch */
    if (has_submitted) {
        int last = 1 - pipe_id;
        if (g_tls_pipe_n_compressed[last] > 0) {
            g_backend_decompress_batch_compact_wait(last,
                g_tls_pipe_n_compressed[last],
                g_tls_pipe_out_ptrs[last],
                g_tls_pipe_out_lens[last]);
        }
        if (verify_batch_crc(info, last, g_tls_pipe_first_block[last],
                             g_tls_pipe_nblocks[last]) != 0) {
            return (total_read > 0) ? (ssize_t)total_read : -1;
        }
        for (int i = 0; i < g_tls_pipe_user_nblocks[last] && count > 0; i++) {
            uint32_t bid = g_tls_pipe_first_block[last] + i;
            off64_t block_off = (bid == g_tls_pipe_first_block[last])
                                ? g_tls_pipe_first_block_off[last] : 0;
            size_t to_copy = GPUC_BLOCK_SIZE - (size_t)block_off;
            if (to_copy > count) to_copy = count;
            memcpy(out_ptr, g_tls_pipe_decomp_bufs[last] + i * GPUC_BLOCK_SIZE + block_off, to_copy);
            out_ptr += to_copy;
            start += to_copy;
            count -= to_copy;
            total_read += to_copy;
        }
        if (g_tls_pipe_nblocks[last] > g_tls_pipe_user_nblocks[last]) {
            if (!info->ra_buf) {
                info->ra_buf = (uint8_t *)malloc(MAX_BATCH_BLOCKS * GPUC_BLOCK_SIZE);
            }
            if (info->ra_buf) {
                size_t ra_len = 0;
                for (int i = g_tls_pipe_user_nblocks[last]; i < g_tls_pipe_nblocks[last]; i++) {
                    uint32_t bid = g_tls_pipe_first_block[last] + i;
                    size_t block_data = info->blocks[bid].orig_len;
                    memcpy(info->ra_buf + ra_len,
                           g_tls_pipe_decomp_bufs[last] + i * GPUC_BLOCK_SIZE, block_data);
                    ra_len += block_data;
                }
                info->ra_start_offset = start;
                info->ra_valid_len = ra_len;
                info->ra_active = 1;
            }
        }
    }

    info->last_read_block = (uint32_t)((orig_start + orig_count - 1) / GPUC_BLOCK_SIZE);
    info->cur_offset = start;
    return (ssize_t)total_read;
}

/* ============================================================
 *  RAW 文件的 read 路径（跳过 header）
 * ============================================================ */

static ssize_t read_raw(int fd, fd_info_t *info, void *buf, size_t count) {
    off64_t log_size = get_logical_size(info);
    if (info->cur_offset >= log_size) return 0;
    if (info->cur_offset + (off64_t)count > log_size)
        count = (size_t)(log_size - info->cur_offset);

    off64_t phys_off = info->cur_offset + (off64_t)info->hdr.header_size;
    ssize_t ret = real_pread64(fd, buf, count, phys_off);
    if (ret > 0) info->cur_offset += ret;
    return ret;
}

/* ============================================================
 *  压缩文件的 pread 路径（指定 offset，不修改 cur_offset）
 * ============================================================ */

static ssize_t read_compressed_at(int fd, fd_info_t *info, void *buf, size_t count, off64_t offset) {
    /* ---- 小文件内联：直接从 header 后读取原始数据（无需 GPU 解压） ---- */
    if (info->hdr.state == GPUC_STATE_INLINE) {
        off64_t log_size = get_logical_size(info);
        if (offset >= log_size) return 0;
        if (offset + (off64_t)count > log_size)
            count = (size_t)(log_size - offset);
        off64_t phys_off = offset + (off64_t)sizeof(info->hdr);
        return real_pread64(fd, buf, count, phys_off);
    }

    ensure_backend_init();
    if (ensure_tls_buffers() != 0 || ensure_batch_tls_buffers() != 0 || ensure_pipe_buffers() != 0) {
        errno = ENOMEM;
        return -1;
    }
    off64_t start = offset;
    off64_t log_size = get_logical_size(info);
    if (start >= log_size) return 0;
    if (start + (off64_t)count > log_size)
        count = (size_t)(log_size - start);

    uint8_t *out_ptr = (uint8_t *)buf;
    size_t total_read = 0;

    int pipe_id = 0;
    int has_submitted = 0;

    while (count > 0) {
        uint32_t first_block = (uint32_t)(start / GPUC_BLOCK_SIZE);
        off64_t first_block_off = start % GPUC_BLOCK_SIZE;
        if (first_block >= info->hdr.num_blocks) break;

        uint32_t last_block = (uint32_t)((start + count - 1) / GPUC_BLOCK_SIZE);
        if (last_block >= info->hdr.num_blocks) last_block = info->hdr.num_blocks - 1;
        int nblocks = (int)(last_block - first_block + 1);
        if (nblocks > MAX_BATCH_BLOCKS) nblocks = MAX_BATCH_BLOCKS;

        /* 消费上一个已提交的 batch */
        if (has_submitted) {
            int prev = 1 - pipe_id;

            if (g_tls_pipe_n_compressed[prev] > 0) {
                g_backend_decompress_batch_compact_wait(prev,
                    g_tls_pipe_n_compressed[prev],
                    g_tls_pipe_out_ptrs[prev],
                    g_tls_pipe_out_lens[prev]);
            }

            if (verify_batch_crc(info, prev, g_tls_pipe_first_block[prev],
                                 g_tls_pipe_nblocks[prev]) != 0) {
                return (total_read > 0) ? (ssize_t)total_read : -1;
            }

            for (int i = 0; i < g_tls_pipe_user_nblocks[prev] && count > 0; i++) {
                uint32_t bid = g_tls_pipe_first_block[prev] + i;
                off64_t block_off = (bid == g_tls_pipe_first_block[prev])
                                    ? g_tls_pipe_first_block_off[prev] : 0;
                size_t to_copy = GPUC_BLOCK_SIZE - (size_t)block_off;
                if (to_copy > count) to_copy = count;
                memcpy(out_ptr, g_tls_pipe_decomp_bufs[prev] + i * GPUC_BLOCK_SIZE + block_off, to_copy);
                out_ptr += to_copy;
                start += to_copy;
                count -= to_copy;
                total_read += to_copy;
            }

            has_submitted = 0;
            if (count == 0) break;
        }

        /* 准备当前 batch（io_uring / pread64） */
        g_tls_pipe_first_block[pipe_id] = first_block;
        g_tls_pipe_first_block_off[pipe_id] = first_block_off;
        g_tls_pipe_user_nblocks[pipe_id] = nblocks;
        g_tls_pipe_nblocks[pipe_id] = nblocks;
        g_tls_pipe_n_compressed[pipe_id] = 0;
        g_tls_pipe_total_compact_len[pipe_id] = 0;

        int use_iouring = g_iouring.initialized;
        if (use_iouring) {
            for (int i = 0; i < nblocks; i++) {
                uint32_t bid = first_block + i;
                struct gpuc_block_entry *be = &info->blocks[bid];
                uint8_t *read_buf = (be->comp_len == be->orig_len)
                    ? g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE
                    : g_tls_iouring_raw_bufs[pipe_id] + i * GPUC_BLOCK_SIZE;
                gpuc_iouring_submit_pread(fd, read_buf, be->comp_len, (off64_t)be->offset);
            }
            if (gpuc_iouring_enter_wait(nblocks, 0) < 0) {
                use_iouring = 0;
            } else {
                int iouring_results[MAX_BATCH_BLOCKS];
                if (gpuc_iouring_wait_all(nblocks, iouring_results) < 0) {
                    use_iouring = 0;
                } else {
                    for (int i = 0; i < nblocks; i++) {
                        uint32_t bid = first_block + i;
                        struct gpuc_block_entry *be = &info->blocks[bid];
                        if (iouring_results[i] < 0 || (size_t)iouring_results[i] != be->comp_len) {
                            fprintf(stderr, "[HOOK] io_uring read failed at block %u: %d\n",
                                    bid, iouring_results[i]);
                            use_iouring = 0;
                            break;
                        }
                    }
                }
            }
        }

        for (int i = 0; i < nblocks; i++) {
            uint32_t bid = first_block + i;
            struct gpuc_block_entry *be = &info->blocks[bid];

            if (be->comp_len == be->orig_len) {
                if (!use_iouring) {
                    ssize_t nr = real_pread64(fd, g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE,
                                              be->comp_len, (off64_t)be->offset);
                    if (nr != (ssize_t)be->comp_len) {
                        return (total_read > 0) ? (ssize_t)total_read : -1;
                    }
                }
                continue;
            }

            uint8_t *raw_buf = use_iouring
                ? g_tls_iouring_raw_bufs[pipe_id] + i * GPUC_BLOCK_SIZE
                : g_tls_comp_buf;

            if (!use_iouring) {
                ssize_t nr = real_pread64(fd, raw_buf, be->comp_len, (off64_t)be->offset);
                if (nr != (ssize_t)be->comp_len) {
                    return (total_read > 0) ? (ssize_t)total_read : -1;
                }
            }

            int file_pos = 0;
            for (int j = 0; j < GC_NCHUNKS && file_pos < (int)be->comp_len; j++) {
                g_tls_pipe_chunk_offsets[pipe_id][g_tls_pipe_n_compressed[pipe_id] * GC_NCHUNKS + j]
                    = g_tls_pipe_total_compact_len[pipe_id] + file_pos;
                uint16_t chunk_len = *(uint16_t *)(raw_buf + file_pos);
                if (chunk_len == 0xFFFF) chunk_len = 2 + GC_CHUNK_SIZE;
                file_pos += chunk_len;
            }
            memcpy(g_tls_pipe_comp_bufs[pipe_id] + g_tls_pipe_total_compact_len[pipe_id],
                   raw_buf, be->comp_len);
            g_tls_pipe_total_compact_len[pipe_id] += be->comp_len;
            g_tls_pipe_out_ptrs[pipe_id][g_tls_pipe_n_compressed[pipe_id]]
                = g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE;
            g_tls_pipe_out_lens[pipe_id][g_tls_pipe_n_compressed[pipe_id]] = be->orig_len;
            g_tls_pipe_n_compressed[pipe_id]++;
        }

        if (g_tls_pipe_n_compressed[pipe_id] > 0) {
            if (g_backend_decompress_batch_compact_async) {
                g_backend_decompress_batch_compact_async(
                    g_tls_pipe_n_compressed[pipe_id],
                    g_tls_pipe_comp_bufs[pipe_id], g_tls_pipe_total_compact_len[pipe_id],
                    g_tls_pipe_chunk_offsets[pipe_id],
                    g_tls_pipe_out_lens[pipe_id],
                    pipe_id);
            } else if (g_backend_decompress_batch_compact) {
                g_backend_decompress_batch_compact(
                    g_tls_pipe_n_compressed[pipe_id],
                    g_tls_pipe_comp_bufs[pipe_id], g_tls_pipe_total_compact_len[pipe_id],
                    g_tls_pipe_chunk_offsets[pipe_id],
                    g_tls_pipe_out_ptrs[pipe_id], g_tls_pipe_out_lens[pipe_id]);
            }
        }

        has_submitted = 1;
        pipe_id = 1 - pipe_id;
    }

    /* 处理最后一个 batch */
    if (has_submitted) {
        int last = 1 - pipe_id;
        if (g_tls_pipe_n_compressed[last] > 0) {
            g_backend_decompress_batch_compact_wait(last,
                g_tls_pipe_n_compressed[last],
                g_tls_pipe_out_ptrs[last],
                g_tls_pipe_out_lens[last]);
        }
        if (verify_batch_crc(info, last, g_tls_pipe_first_block[last],
                             g_tls_pipe_nblocks[last]) != 0) {
            return (total_read > 0) ? (ssize_t)total_read : -1;
        }
        for (int i = 0; i < g_tls_pipe_user_nblocks[last] && count > 0; i++) {
            uint32_t bid = g_tls_pipe_first_block[last] + i;
            off64_t block_off = (bid == g_tls_pipe_first_block[last])
                                ? g_tls_pipe_first_block_off[last] : 0;
            size_t to_copy = GPUC_BLOCK_SIZE - (size_t)block_off;
            if (to_copy > count) to_copy = count;
            memcpy(out_ptr, g_tls_pipe_decomp_bufs[last] + i * GPUC_BLOCK_SIZE + block_off, to_copy);
            out_ptr += to_copy;
            start += to_copy;
            count -= to_copy;
            total_read += to_copy;
        }
    }

    return (ssize_t)total_read;
}


/* ============================================================
 *  构造函数 / 析构函数
 * ============================================================ */

void __attribute__((constructor(101))) hook_init(void) {
    FILE *f = fopen("/tmp/hook_init_ran_fio.txt", "w"); if (f) { fprintf(f, "ran\n"); fclose(f); }
    real_read     = dlsym(RTLD_NEXT, "read");
    real_write    = dlsym(RTLD_NEXT, "write");
    real_open     = dlsym(RTLD_NEXT, "open");
    real_open64   = dlsym(RTLD_NEXT, "open64");
    real_creat    = dlsym(RTLD_NEXT, "creat");
    real_lseek    = dlsym(RTLD_NEXT, "lseek");
    real_lseek64  = dlsym(RTLD_NEXT, "lseek64");
    real_close    = dlsym(RTLD_NEXT, "close");
    real_pread64  = dlsym(RTLD_NEXT, "pread64");
    real_pwrite64 = dlsym(RTLD_NEXT, "pwrite64");
    real_readv    = dlsym(RTLD_NEXT, "readv");
    real_writev   = dlsym(RTLD_NEXT, "writev");
    real_openat   = dlsym(RTLD_NEXT, "openat");
    real_openat64 = dlsym(RTLD_NEXT, "openat64");
    real_fxstat   = dlsym(RTLD_NEXT, "__fxstat");
    real_fxstat64 = dlsym(RTLD_NEXT, "__fxstat64");
    real_xstat    = dlsym(RTLD_NEXT, "__xstat");
    real_xstat64  = dlsym(RTLD_NEXT, "__xstat64");
    real_lxstat   = dlsym(RTLD_NEXT, "__lxstat");
    real_lxstat64 = dlsym(RTLD_NEXT, "__lxstat64");
    real_ftruncate = dlsym(RTLD_NEXT, "ftruncate");
    real_truncate  = dlsym(RTLD_NEXT, "truncate");
    real_dup       = dlsym(RTLD_NEXT, "dup");
    real_dup2      = dlsym(RTLD_NEXT, "dup2");
    real_dup3      = dlsym(RTLD_NEXT, "dup3");
    real_sendfile  = dlsym(RTLD_NEXT, "sendfile");
    real_mmap      = dlsym(RTLD_NEXT, "mmap");
    real_munmap    = dlsym(RTLD_NEXT, "munmap");
    real_msync     = dlsym(RTLD_NEXT, "msync");

    /* DEBUG: check dlsym results */
    if (!real_read)     fprintf(stderr, "[HOOK] WARN: dlsym(read) failed\n");
    if (!real_write)    fprintf(stderr, "[HOOK] WARN: dlsym(write) failed\n");
    if (!real_open)     fprintf(stderr, "[HOOK] WARN: dlsym(open) failed\n");
    if (!real_open64)   fprintf(stderr, "[HOOK] WARN: dlsym(open64) failed\n");
    if (!real_creat)    fprintf(stderr, "[HOOK] WARN: dlsym(creat) failed\n");
    if (!real_lseek)    fprintf(stderr, "[HOOK] WARN: dlsym(lseek) failed\n");
    if (!real_lseek64)  fprintf(stderr, "[HOOK] WARN: dlsym(lseek64) failed\n");
    if (!real_close)    fprintf(stderr, "[HOOK] WARN: dlsym(close) failed\n");
    if (!real_pread64)  fprintf(stderr, "[HOOK] WARN: dlsym(pread64) failed\n");
    if (!real_pwrite64) fprintf(stderr, "[HOOK] WARN: dlsym(pwrite64) failed\n");
    if (!real_readv)    fprintf(stderr, "[HOOK] WARN: dlsym(readv) failed\n");
    if (!real_writev)   fprintf(stderr, "[HOOK] WARN: dlsym(writev) failed\n");
    if (!real_openat)   fprintf(stderr, "[HOOK] WARN: dlsym(openat) failed\n");
    if (!real_openat64) fprintf(stderr, "[HOOK] WARN: dlsym(openat64) failed\n");
    if (!real_fxstat)   fprintf(stderr, "[HOOK] WARN: dlsym(__fxstat) failed\n");
    if (!real_fxstat64) fprintf(stderr, "[HOOK] WARN: dlsym(__fxstat64) failed\n");
    if (!real_xstat)    fprintf(stderr, "[HOOK] WARN: dlsym(__xstat) failed\n");
    if (!real_xstat64)  fprintf(stderr, "[HOOK] WARN: dlsym(__xstat64) failed\n");
    if (!real_lxstat)   fprintf(stderr, "[HOOK] WARN: dlsym(__lxstat) failed\n");
    if (!real_lxstat64) fprintf(stderr, "[HOOK] WARN: dlsym(__lxstat64) failed\n");
    if (!real_ftruncate) fprintf(stderr, "[HOOK] WARN: dlsym(ftruncate) failed\n");
    if (!real_truncate)  fprintf(stderr, "[HOOK] WARN: dlsym(truncate) failed\n");
    if (!real_dup)       fprintf(stderr, "[HOOK] WARN: dlsym(dup) failed\n");
    if (!real_dup2)      fprintf(stderr, "[HOOK] WARN: dlsym(dup2) failed\n");
    if (!real_dup3)      fprintf(stderr, "[HOOK] WARN: dlsym(dup3) failed\n");
    FILE *f2 = fopen("/tmp/dlsym_results.txt", "w");
    if (f2) {
        fprintf(f2, "real_read=%p real_write=%p real_open=%p real_close=%p\n",
                real_read, real_write, real_open, real_close);
        fclose(f2);
    }
    if (!real_sendfile)  fprintf(stderr, "[HOOK] WARN: dlsym(sendfile) failed\n");
    if (!real_mmap)      fprintf(stderr, "[HOOK] WARN: dlsym(mmap) failed\n");
    if (!real_munmap)    fprintf(stderr, "[HOOK] WARN: dlsym(munmap) failed\n");
    if (!real_msync)     fprintf(stderr, "[HOOK] WARN: dlsym(msync) failed\n");
    if (getenv("GPUC_NO_HOOK")) {
        g_hooks_disabled = 1;
        fprintf(stderr, "[HOOK] ALL HOOKS DISABLED by GPUC_NO_HOOK\n");
    } else {
        g_hooks_disabled = 0;  /* hook_init 成功完成后启用拦截 */
    }

    /* -------- 选择压缩后端：cpu / gpu（默认 gpu，GPU 失败自动 fallback）-------- */
    static int g_backend_msg_done = 0;
    int quiet = !!getenv("GPUCOMPRESS_QUIET");
#ifdef CPU_ONLY_BUILD
    g_backend_name = "cpu";
    g_backend_compress_init = cpu_compress_init;
    g_backend_compress_fini = cpu_compress_fini;
    g_backend_decompress_128k = cpu_decompress_128k;
    g_backend_decompress_batch = cpu_decompress_batch;
    g_backend_decompress_batch_compact = cpu_decompress_batch_compact;
    g_backend_decompress_batch_compact_async = cpu_decompress_batch_compact_async;
    g_backend_decompress_batch_compact_wait = cpu_decompress_batch_compact_wait;
    if (!quiet && !g_backend_msg_done) {
        fprintf(stderr, "[HOOK] Backend: CPU (pure software, CPU-only build)\n");
        g_backend_msg_done = 1;
    }
#else
    const char *backend_env = getenv("GPUCOMPRESS_BACKEND");
    if (backend_env && strcmp(backend_env, "cpu") == 0) {
        /* 用户强制指定 CPU */
        g_backend_name = "cpu";
        g_backend_compress_init = cpu_compress_init;
        g_backend_compress_fini = cpu_compress_fini;
        g_backend_decompress_128k = cpu_decompress_128k;
        g_backend_decompress_batch = cpu_decompress_batch;
        g_backend_decompress_batch_compact = cpu_decompress_batch_compact;
        g_backend_decompress_batch_compact_async = cpu_decompress_batch_compact_async;
        g_backend_decompress_batch_compact_wait = cpu_decompress_batch_compact_wait;
        if (!quiet && !g_backend_msg_done) {
            fprintf(stderr, "[HOOK] Backend selected: CPU (pure software decompression)\n");
            g_backend_msg_done = 1;
        }
    } else {
        /* 默认尝试 GPU，但延迟到第一次 I/O 时初始化（避免 constructor 中 CUDA 未就绪） */
        g_backend_name = "gpu";
        g_backend_compress_init = gpu_compress_init;
        g_backend_compress_fini = gpu_compress_fini;
        g_backend_decompress_128k = gpu_decompress_128k;
        g_backend_decompress_batch = gpu_decompress_batch;
        g_backend_decompress_batch_compact = gpu_decompress_batch_compact;
        g_backend_decompress_batch_compact_async = gpu_decompress_batch_compact_async;
        g_backend_decompress_batch_compact_wait = gpu_decompress_batch_compact_wait;
        /* g_backend_initialized = 0，让 ensure_backend_init() 在第一次 I/O 时调用 */
        if (!quiet && !g_backend_msg_done) {
            fprintf(stderr, "[HOOK] Backend selected: GPU (CUDA offload, lazy init)\n");
            g_backend_msg_done = 1;
        }
    }
#endif

    /* 初始化 io_uring（批量异步 I/O），失败静默 fallback 到 pread64 */
    if (gpuc_iouring_init(32) == 0) {
        if (!quiet) fprintf(stderr, "[HOOK] io_uring: async I/O enabled\n");
    }
}

void __attribute__((destructor)) hook_fini(void) {
    if (g_backend_compress_fini) g_backend_compress_fini();
    gpuc_iouring_fini();
}

/* ============================================================
 *  拦截函数实现
 * ============================================================ */

int open(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    if (g_hooks_disabled) {

        if (!real_open) { errno = ENOSYS; return -1; }

        return real_open(pathname, flags, mode);

    }
    int fd = real_open(pathname, flags, mode);
    if (fd < 0) return fd;
    if (!is_regular_file(fd)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    info->active = 1;
    info->phys_size = get_phys_size(fd);

    if (info->phys_size == 0) {
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    } else if (info->phys_size >= (off64_t)sizeof(struct gpuc_header)) {
        read_header(fd, info);
    }

    set_fd_info(fd, info);
    return fd;
}

int open64(const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }

    if (g_hooks_disabled) {

        if (!real_open64) { errno = ENOSYS; return -1; }

        return real_open64(pathname, flags, mode);

    }
    int fd = real_open64(pathname, flags, mode);
    if (fd < 0) return fd;
    if (!is_regular_file(fd)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    info->active = 1;
    info->phys_size = get_phys_size(fd);

    if (info->phys_size == 0) {
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    } else if (info->phys_size >= (off64_t)sizeof(struct gpuc_header)) {
        read_header(fd, info);
    }

    set_fd_info(fd, info);
    return fd;
}

int creat(const char *pathname, mode_t mode) {
    if (g_hooks_disabled) {
        if (!real_creat) { errno = ENOSYS; return -1; }
        return real_creat(pathname, mode);
    }
    int fd = real_creat(pathname, mode);
    if (fd < 0) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    info->active = 1;
    info->phys_size = get_phys_size(fd);

    if (info->phys_size == 0) {
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    }

    set_fd_info(fd, info);
    return fd;
}

ssize_t read(int fd, void *buf, size_t count) {
    if (g_hooks_disabled) {
        if (!real_read) { errno = ENOSYS; return -1; }
        return real_read(fd, buf, count);
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_read(fd, buf, count);
    }
    if (info->is_compressed) {
        return read_compressed(fd, info, buf, count);
    }
    return read_raw(fd, info, buf, count);
}

ssize_t write(int fd, const void *buf, size_t count) {
    if (g_hooks_disabled) {
        if (!real_write) { errno = EBADF; return -1; }
        return real_write(fd, buf, count);
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        if (!real_write) { syscall(SYS_write, 2, "[HOOK] real_write NULL\n", 24); errno = EBADF; return -1; }
        return real_write(fd, buf, count);
    }

    /* 对已压缩文件拒绝写入，防止破坏块索引结构 */
    if (info->is_compressed) {
        errno = EROFS;
        return -1;
    }

    off64_t phys_off = info->cur_offset + (off64_t)info->hdr.header_size;
    ssize_t ret = real_pwrite64(fd, buf, count, phys_off);
    if (ret > 0) {
        info->cur_offset += ret;
        info->phys_size = get_phys_size(fd);
    }
    return ret;
}

off_t lseek(int fd, off_t offset, int whence) {
    if (g_hooks_disabled) {
        if (!real_lseek) { errno = ENOSYS; return -1; }
        return real_lseek(fd, offset, whence);
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_lseek(fd, offset, whence);
    }

    off64_t log_size = get_logical_size(info);
    off64_t new_off = 0;

    switch (whence) {
        case SEEK_SET: new_off = offset; break;
        case SEEK_CUR: new_off = info->cur_offset + offset; break;
        case SEEK_END: new_off = log_size + offset; break;
        default:
            errno = EINVAL;
            return (off_t)-1;
    }
    if (new_off < 0) new_off = 0;
    /* lseek 改变偏移时，预读缓存失效 */
    if (info->ra_active && new_off != info->cur_offset) {
        info->ra_active = 0;
    }
    info->cur_offset = new_off;

    /* 同步底层物理偏移（部分程序依赖内核中的文件偏移） */
    off64_t phys_off = new_off + (off64_t)info->hdr.header_size;
    real_lseek64(fd, phys_off, SEEK_SET);

    return (off_t)new_off;
}

off64_t lseek64(int fd, off64_t offset, int whence) {
    if (g_hooks_disabled) {
        if (!real_lseek64) { errno = ENOSYS; return -1; }
        return real_lseek64(fd, offset, whence);
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_lseek64(fd, offset, whence);
    }

    off64_t log_size = get_logical_size(info);
    off64_t new_off = 0;

    switch (whence) {
        case SEEK_SET: new_off = offset; break;
        case SEEK_CUR: new_off = info->cur_offset + offset; break;
        case SEEK_END: new_off = log_size + offset; break;
        default:
            errno = EINVAL;
            return (off64_t)-1;
    }
    if (new_off < 0) new_off = 0;
    /* lseek 改变偏移时，预读缓存失效 */
    if (info->ra_active && new_off != info->cur_offset) {
        info->ra_active = 0;
    }
    info->cur_offset = new_off;

    off64_t phys_off = new_off + (off64_t)info->hdr.header_size;
    real_lseek64(fd, phys_off, SEEK_SET);

    return new_off;
}

int close(int fd) {
    if (g_hooks_disabled) {
        if (!real_close) { errno = EBADF; return -1; }
        return real_close(fd);
    }
    clear_fd_info(fd);
    return real_close(fd);
}

/* ============================================================
 *  ftruncate / truncate 拦截
 * ============================================================ */

int ftruncate(int fd, off_t length) {
    if (g_hooks_disabled) {
        if (!real_ftruncate) { errno = ENOSYS; return -1; }
        return real_ftruncate(fd, length);
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_ftruncate(fd, length);
    }
    off_t phys_len = length + (off_t)info->hdr.header_size;
    return real_ftruncate(fd, phys_len);
}

int truncate(const char *path, off_t length) {
    if (g_hooks_disabled) {
        if (!real_truncate) { errno = ENOSYS; return -1; }
        return real_truncate(path, length);
    }
    /* 尝试先 open 获取 fd_info，若文件是 GPUC 则调整长度 */
    int fd = real_open(path, O_RDONLY);
    if (fd >= 0) {
        fd_info_t *info = get_fd_info(fd);
        if (info && info->has_header) {
            off_t phys_len = length + (off_t)info->hdr.header_size;
            real_close(fd);
            return real_truncate(path, phys_len);
        }
        real_close(fd);
    }
    return real_truncate(path, length);
}

/* ============================================================
 *  sendfile 拦截（压缩文件 fallback 到 read+write）
 * ============================================================ */

static ssize_t sendfile_fallback(int out_fd, int in_fd, off_t *offset, size_t count) {
    char buf[65536];
    size_t total = 0;
    off_t off = offset ? *offset : 0;

    while (count > 0) {
        size_t to_read = count < sizeof(buf) ? count : sizeof(buf);
        ssize_t nr;
        if (offset) {
            nr = pread64(in_fd, buf, to_read, off);
        } else {
            nr = read(in_fd, buf, to_read);
        }
        if (nr <= 0) {
            if (nr < 0 && total > 0) return (ssize_t)total;
            if (nr < 0) return -1;
            break;
        }

        size_t written = 0;
        while (written < (size_t)nr) {
            ssize_t nw = write(out_fd, buf + written, nr - written);
            if (nw < 0) {
                if (total > 0) return (ssize_t)total;
                return -1;
            }
            written += (size_t)nw;
        }

        total += nr;
        off += nr;
        count -= nr;
    }

    if (offset) *offset = off;
    return total > 0 ? (ssize_t)total : 0;
}

ssize_t sendfile(int out_fd, int in_fd, off_t *offset, size_t count) {
    if (g_hooks_disabled) {
        if (!real_sendfile) { errno = ENOSYS; return -1; }
        return real_sendfile(out_fd, in_fd, offset, count);
    }
    fd_info_t *info = get_fd_info(in_fd);
    if (info && info->has_header && info->is_compressed) {
        return sendfile_fallback(out_fd, in_fd, offset, count);
    }
    return real_sendfile(out_fd, in_fd, offset, count);
}

/* ============================================================
 *  dup / dup2 / dup3 拦截（复制 fd_info）
 * ============================================================ */

int dup(int oldfd) {
    if (g_hooks_disabled) {
        if (!real_dup) { errno = ENOSYS; return -1; }
        return real_dup(oldfd);
    }
    int newfd = real_dup(oldfd);
    if (newfd >= 0) {
        fd_info_t *old_info = get_fd_info(oldfd);
        if (old_info && old_info->has_header) {
            fd_info_t *new_info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
            *new_info = *old_info;
            if (old_info->blocks && old_info->hdr.num_blocks > 0) {
                size_t blocks_size = old_info->hdr.num_blocks * sizeof(struct gpuc_block_entry);
                new_info->blocks = (struct gpuc_block_entry *)malloc(blocks_size);
                if (new_info->blocks) {
                    memcpy(new_info->blocks, old_info->blocks, blocks_size);
                }
            }
            set_fd_info(newfd, new_info);
        }
    }
    return newfd;
}

int dup2(int oldfd, int newfd) {
    if (g_hooks_disabled) {
        if (!real_dup2) { errno = ENOSYS; return -1; }
        return real_dup2(oldfd, newfd);
    }
    int ret = real_dup2(oldfd, newfd);
    if (ret >= 0) {
        clear_fd_info(newfd);
        fd_info_t *old_info = get_fd_info(oldfd);
        if (old_info && old_info->has_header) {
            fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
            *info = *old_info;
            if (old_info->blocks && old_info->hdr.num_blocks > 0) {
                size_t blocks_size = old_info->hdr.num_blocks * sizeof(struct gpuc_block_entry);
                info->blocks = (struct gpuc_block_entry *)malloc(blocks_size);
                if (info->blocks) {
                    memcpy(info->blocks, old_info->blocks, blocks_size);
                }
            }
            set_fd_info(newfd, info);
        }
    }
    return ret;
}

int dup3(int oldfd, int newfd, int flags) {
    if (g_hooks_disabled) {
        if (!real_dup3) { errno = ENOSYS; return -1; }
        return real_dup3(oldfd, newfd, flags);
    }
    int ret = real_dup3(oldfd, newfd, flags);
    if (ret >= 0) {
        clear_fd_info(newfd);
        fd_info_t *old_info = get_fd_info(oldfd);
        if (old_info && old_info->has_header) {
            fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
            *info = *old_info;
            if (old_info->blocks && old_info->hdr.num_blocks > 0) {
                size_t blocks_size = old_info->hdr.num_blocks * sizeof(struct gpuc_block_entry);
                info->blocks = (struct gpuc_block_entry *)malloc(blocks_size);
                if (info->blocks) {
                    memcpy(info->blocks, old_info->blocks, blocks_size);
                }
            }
            set_fd_info(newfd, info);
        }
    }
    return ret;
}

/* ============================================================
 *  pread64 / pwrite64 拦截（偏移转换）
 * ============================================================ */

ssize_t pread64(int fd, void *buf, size_t count, off64_t offset) {
    if (g_hooks_disabled) {
        if (!real_pread64) { errno = ENOSYS; return -1; }
        return real_pread64(fd, buf, count, offset);
    }
    if (offset < 0) {
        errno = EINVAL;
        return -1;
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_pread64(fd, buf, count, offset);
    }
    if (info->is_compressed) {
        return read_compressed_at(fd, info, buf, count, offset);
    }
    off64_t phys_off = offset + (off64_t)info->hdr.header_size;
    return real_pread64(fd, buf, count, phys_off);
}

ssize_t pwrite64(int fd, const void *buf, size_t count, off64_t offset) {
    if (g_hooks_disabled) {
        if (!real_pwrite64) { errno = ENOSYS; return -1; }
        return real_pwrite64(fd, buf, count, offset);
    }
    if (offset < 0) {
        errno = EINVAL;
        return -1;
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_pwrite64(fd, buf, count, offset);
    }
    off64_t phys_off = offset + (off64_t)info->hdr.header_size;
    return real_pwrite64(fd, buf, count, phys_off);
}

/* pread / pwrite 别名（某些程序直接调用 pread 而非 pread64） */
ssize_t pread(int fd, void *buf, size_t count, off_t offset) {
    return pread64(fd, buf, count, (off64_t)offset);
}

ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset) {
    return pwrite64(fd, buf, count, (off64_t)offset);
}

/* ============================================================
 *  readv / writev 拦截（透传，依赖 lseek 维护的底层偏移）
 * ============================================================ */

ssize_t readv(int fd, const struct iovec *iov, int iovcnt) {
    if (g_hooks_disabled) {
        if (!real_readv) { errno = ENOSYS; return -1; }
        return real_readv(fd, iov, iovcnt);
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_readv(fd, iov, iovcnt);
    }
    if (info->is_compressed) {
        /* 简化处理：逐个 iov 用 read 模拟 */
        ssize_t total = 0;
        for (int i = 0; i < iovcnt; i++) {
            ssize_t n = read(fd, iov[i].iov_base, iov[i].iov_len);
            if (n < 0) return n;
            total += n;
            if ((size_t)n < iov[i].iov_len) break;
        }
        return total;
    }
    return real_readv(fd, iov, iovcnt);
}

ssize_t writev(int fd, const struct iovec *iov, int iovcnt) {
    if (g_hooks_disabled) {
        if (!real_writev) { errno = ENOSYS; return -1; }
        return real_writev(fd, iov, iovcnt);
    }
    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
        return real_writev(fd, iov, iovcnt);
    }
    /* RAW 文件：底层偏移已由 lseek 同步，直接透传 */
    return real_writev(fd, iov, iovcnt);
}

/* ============================================================
 *  openat / openat64 拦截
 * ============================================================ */

int openat(int dirfd, const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    if (g_hooks_disabled) {
        if (!real_openat) { errno = ENOSYS; return -1; }
        return real_openat(dirfd, pathname, flags, mode);
    }
    int fd = real_openat(dirfd, pathname, flags, mode);
    if (fd < 0) return fd;
    if (!is_regular_file(fd)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    info->active = 1;
    info->phys_size = get_phys_size(fd);
    if (info->phys_size == 0) {
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    } else if (info->phys_size >= (off64_t)sizeof(struct gpuc_header)) {
        read_header(fd, info);
    }
    set_fd_info(fd, info);
    return fd;
}

int openat64(int dirfd, const char *pathname, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = va_arg(ap, mode_t);
        va_end(ap);
    }
    if (g_hooks_disabled) {
        if (!real_openat64) { errno = ENOSYS; return -1; }
        return real_openat64(dirfd, pathname, flags, mode);
    }
    int fd = real_openat64(dirfd, pathname, flags, mode);
    if (fd < 0) return fd;
    if (!is_regular_file(fd)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    info->active = 1;
    info->phys_size = get_phys_size(fd);
    if (info->phys_size == 0) {
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    } else if (info->phys_size >= (off64_t)sizeof(struct gpuc_header)) {
        read_header(fd, info);
    }
    set_fd_info(fd, info);
    return fd;
}

int __fxstat(int ver, int fd, struct stat *buf) {
    if (g_hooks_disabled) {
        if (!real_fxstat) { errno = ENOSYS; return -1; }
        return real_fxstat(ver, fd, buf);
    }
    int ret = real_fxstat(ver, fd, buf);
    if (ret == 0) {
        fd_info_t *info = get_fd_info(fd);
        if (info && info->has_header) {
            off64_t log_size = get_logical_size(info);
            buf->st_size = (off_t)log_size;
        }
    }
    return ret;
}

int __fxstat64(int ver, int fd, struct stat64 *buf) {
    if (g_hooks_disabled) {
        if (!real_fxstat64) { errno = ENOSYS; return -1; }
        return real_fxstat64(ver, fd, buf);
    }
    int ret = real_fxstat64(ver, fd, buf);
    if (ret == 0) {
        fd_info_t *info = get_fd_info(fd);
        if (info && info->has_header) {
            off64_t log_size = get_logical_size(info);
            buf->st_size = log_size;
        }
    }
    return ret;
}

/* ============================================================
 *  __xstat / __xstat64 / __lxstat / __lxstat64 拦截
 *  让 ls -l 显示逻辑大小而非物理大小
 * ============================================================ */

static int adjust_stat_size(const char *pathname, struct stat *buf) {
    if (!S_ISREG(buf->st_mode)) return 0;
    if (buf->st_size < (off_t)sizeof(struct gpuc_header)) return 0;

    int fd = real_open(pathname, O_RDONLY);
    if (fd < 0) return 0;

    struct gpuc_header hdr;
    ssize_t n = real_pread64(fd, &hdr, sizeof(hdr), 0);
    real_close(fd);

    if (n != (ssize_t)sizeof(hdr)) return 0;
    if (!gpuc_is_header(&hdr)) return 0;

    if (hdr.state == GPUC_STATE_COMPRESSED || hdr.state == GPUC_STATE_INLINE) {
        buf->st_size = (off_t)hdr.orig_size;
    } else {
        buf->st_size = buf->st_size - (off_t)sizeof(hdr);
    }
    return 1;
}

static int adjust_stat64_size(const char *pathname, struct stat64 *buf) {
    if (!S_ISREG(buf->st_mode)) return 0;
    if (buf->st_size < (off64_t)sizeof(struct gpuc_header)) return 0;

    int fd = real_open(pathname, O_RDONLY);
    if (fd < 0) return 0;

    struct gpuc_header hdr;
    ssize_t n = real_pread64(fd, &hdr, sizeof(hdr), 0);
    real_close(fd);

    if (n != (ssize_t)sizeof(hdr)) return 0;
    if (!gpuc_is_header(&hdr)) return 0;

    if (hdr.state == GPUC_STATE_COMPRESSED || hdr.state == GPUC_STATE_INLINE) {
        buf->st_size = (off64_t)hdr.orig_size;
    } else {
        buf->st_size = buf->st_size - (off64_t)sizeof(hdr);
    }
    return 1;
}

int __xstat(int ver, const char *pathname, struct stat *buf) {
    if (g_hooks_disabled) {
        if (!real_xstat) { errno = ENOSYS; return -1; }
        return real_xstat(ver, pathname, buf);
    }
    int ret = real_xstat(ver, pathname, buf);
    if (ret == 0) {
        adjust_stat_size(pathname, buf);
    }
    return ret;
}

int __xstat64(int ver, const char *pathname, struct stat64 *buf) {
    if (g_hooks_disabled) {
        if (!real_xstat64) { errno = ENOSYS; return -1; }
        return real_xstat64(ver, pathname, buf);
    }
    int ret = real_xstat64(ver, pathname, buf);
    if (ret == 0) {
        adjust_stat64_size(pathname, buf);
    }
    return ret;
}

int __lxstat(int ver, const char *pathname, struct stat *buf) {
    if (g_hooks_disabled) {
        if (!real_lxstat) { errno = ENOSYS; return -1; }
        return real_lxstat(ver, pathname, buf);
    }
    int ret = real_lxstat(ver, pathname, buf);
    if (ret == 0) {
        adjust_stat_size(pathname, buf);
    }
    return ret;
}

int __lxstat64(int ver, const char *pathname, struct stat64 *buf) {
    if (g_hooks_disabled) {
        if (!real_lxstat64) { errno = ENOSYS; return -1; }
        return real_lxstat64(ver, pathname, buf);
    }
    int ret = real_lxstat64(ver, pathname, buf);
    if (ret == 0) {
        adjust_stat64_size(pathname, buf);
    }
    return ret;
}

/* ============================================================
 *  mmap / munmap / msync 拦截
 *  对 COMPRESSED 文件：预解压到匿名内存，返回匿名地址
 *  对 RAW 文件：直接透传
 * ============================================================ */

#define MAX_MMAP_TRACK 64

typedef struct {
    void *addr;       /* 返回给应用的地址 */
    size_t len;       /* 映射长度 */
    void *buf;        /* 匿名内存基址（可能与 addr 相同） */
    size_t buf_len;   /* 匿名内存总长度 */
    int active;
} mmap_track_t;

static mmap_track_t g_mmap_table[MAX_MMAP_TRACK];
static pthread_mutex_t g_mmap_lock = PTHREAD_MUTEX_INITIALIZER;

static int add_mmap_track(void *addr, size_t len, void *buf, size_t buf_len) {
    pthread_mutex_lock(&g_mmap_lock);
    for (int i = 0; i < MAX_MMAP_TRACK; i++) {
        if (!g_mmap_table[i].active) {
            g_mmap_table[i].addr = addr;
            g_mmap_table[i].len = len;
            g_mmap_table[i].buf = buf;
            g_mmap_table[i].buf_len = buf_len;
            g_mmap_table[i].active = 1;
            pthread_mutex_unlock(&g_mmap_lock);
            return 0;
        }
    }
    pthread_mutex_unlock(&g_mmap_lock);
    return -1;
}

static void remove_mmap_track(void *addr) {
    pthread_mutex_lock(&g_mmap_lock);
    for (int i = 0; i < MAX_MMAP_TRACK; i++) {
        if (g_mmap_table[i].active && g_mmap_table[i].addr == addr) {
            g_mmap_table[i].active = 0;
            break;
        }
    }
    pthread_mutex_unlock(&g_mmap_lock);
}

static int is_tracked_mmap(void *addr) {
    pthread_mutex_lock(&g_mmap_lock);
    for (int i = 0; i < MAX_MMAP_TRACK; i++) {
        if (g_mmap_table[i].active && g_mmap_table[i].addr == addr) {
            pthread_mutex_unlock(&g_mmap_lock);
            return 1;
        }
    }
    pthread_mutex_unlock(&g_mmap_lock);
    return 0;
}

void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    if (g_hooks_disabled || !real_mmap) {
        if (!real_mmap) { errno = ENOSYS; return MAP_FAILED; }
        return real_mmap(addr, length, prot, flags, fd, offset);
    }

    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header || !info->is_compressed) {
        return real_mmap(addr, length, prot, flags, fd, offset);
    }

    /* 只处理 MAP_PRIVATE 的读映射（最常见场景） */
    if (!(flags & MAP_PRIVATE)) {
        /* MAP_SHARED 暂不支持，透传（应用看到压缩数据） */
        return real_mmap(addr, length, prot, flags, fd, offset);
    }

    /* 检查映射范围是否合理 */
    off64_t log_size = get_logical_size(info);
    if (offset < 0 || (off64_t)offset >= log_size) {
        errno = EINVAL;
        return MAP_FAILED;
    }
    if ((off64_t)offset + (off64_t)length > log_size) {
        length = (size_t)(log_size - offset);
    }

    /* 分配匿名内存 */
    void *buf = real_mmap(NULL, length, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) return MAP_FAILED;

    /* 用 read_compressed_at 预解压数据到匿名内存 */
    ssize_t nread = read_compressed_at(fd, info, buf, length, (off64_t)offset);
    if (nread < 0 || (size_t)nread < length) {
        real_munmap(buf, length);
        errno = EIO;
        return MAP_FAILED;
    }

    /* 按请求调整保护位 */
    if ((prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) != (PROT_READ | PROT_WRITE)) {
        if (mprotect(buf, length, prot) != 0) {
            real_munmap(buf, length);
            errno = ENOMEM;
            return MAP_FAILED;
        }
    }

    /* 记录映射 */
    if (add_mmap_track(buf, length, buf, length) != 0) {
        real_munmap(buf, length);
        errno = ENOMEM;
        return MAP_FAILED;
    }

    return buf;
}

int munmap(void *addr, size_t length) {
    (void)length;
    if (!real_munmap) { errno = ENOSYS; return -1; }

    if (is_tracked_mmap(addr)) {
        remove_mmap_track(addr);
        return real_munmap(addr, length);
    }
    return real_munmap(addr, length);
}

int msync(void *addr, size_t length, int flags) {
    (void)length; (void)flags;
    if (!real_msync) { errno = ENOSYS; return -1; }

    if (is_tracked_mmap(addr)) {
        /* 匿名 MAP_PRIVATE 映射不需要 sync */
        return 0;
    }
    return real_msync(addr, length, flags);
}

