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
#include <sys/xattr.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <stdint.h>
#include <errno.h>
#include <stdarg.h>
#include <time.h>

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
__attribute__((weak)) int  gpu_lz4_decompress_batch(int n,
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
#ifdef GPUC_NO_PINNED
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
#endif

/* nvCOMP LZ4 has substantially higher launch overhead than the custom SGLZ
 * kernel. Keep its sequential read-ahead batch independent from the SGLZ
 * tuning result. */
#define LZ4_BATCH_BLOCKS 4
#define TLS_BATCH_CAPACITY LZ4_BATCH_BLOCKS

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
static int     (*real_rename)(const char *, const char *);
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
 *  GPU 负载检测：高负载时自动 fallback CPU 后端
 * ============================================================ */
#ifndef GPUC_NO_FALLBACK
static __thread int g_tls_use_cpu = 0;
static __thread time_t g_tls_last_check = 0;

static int should_cpu_fallback(void) {
    /*
     * Spawning nvidia-smi from a hot read path is expensive and every child
     * inherits LD_PRELOAD. Keep this legacy policy opt-in until it is replaced
     * by an in-process NVML sampler.
     */
    const char *enabled = getenv("GPUC_ENABLE_NVIDIA_SMI_FALLBACK");
    if (!enabled || strcmp(enabled, "1") != 0) return 0;

    time_t now = time(NULL);
    if (now != g_tls_last_check) {
        FILE *f = popen("nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits", "r");
        if (f) {
            int util = 0;
            if (fscanf(f, "%d", &util) == 1) {
                g_tls_use_cpu = (util > 80);
            }
            pclose(f);
        }
        g_tls_last_check = now;
    }
    return g_tls_use_cpu;
}
#endif

typedef int (*decomp_async_fn_t)(int, const uint8_t *, size_t, const int *, const size_t *, int);
typedef int (*decomp_wait_fn_t)(int, int, uint8_t **, const size_t *);

/* ============================================================
 *  辅助：判断 fd 是否为普通文件（只 hook 普通文件）
 * ============================================================ */
static int is_regular_file(int fd) {
    struct stat64 st;
    if (fstat64(fd, &st) != 0) return 0;
    return S_ISREG(st.st_mode);
}

/* ============================================================
 *  数据库 / 日志文件白名单
 *  这些文件依赖固定 offset 0 的 magic/header，不能附加 GPUC header
 * ============================================================ */
static const char *g_db_whitelist[] = {
    ".db",          /* SQLite 主数据库 */
    ".db-journal",  /* SQLite journal */
    ".db-wal",      /* SQLite WAL */
    ".wal",         /* 通用 WAL */
    ".log",         /* 通用日志（保守匹配） */
    ".ldb",         /* LevelDB SST */
    ".sst",         /* RocksDB/LevelDB SST */
    "CURRENT",      /* LevelDB manifest 指针 */
    "CURRENT.",     /* LevelDB CURRENT.tmp / CURRENT.bak 等 */
    "MANIFEST-",    /* LevelDB/RocksDB manifest */
    NULL
};

static int is_whitelisted_path(const char *pathname) {
    if (!pathname) return 0;
    if (getenv("GPUC_NO_DB_WHITELIST")) return 0;

    const char *name = pathname;
    const char *slash = strrchr(pathname, '/');
    if (slash) name = slash + 1;
    if (*name == '\0') return 0;

    /* 追加用户自定义模式（逗号分隔），例如 *.custom */
    const char *extra = getenv("GPUC_WHITELIST");
    if (extra && *extra) {
        char buf[256];
        strncpy(buf, extra, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        char *save = NULL;
        for (char *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
            /* 去掉前导空白和可能的 *. */
            while (*tok == ' ' || *tok == '\t') tok++;
            if (*tok == '*') tok++;
            if (*tok == '.') tok++;
            size_t tlen = strlen(tok);
            size_t nlen = strlen(name);
            if (tlen > 0 && tlen < nlen && strcasecmp(name + nlen - tlen, tok) == 0)
                return 1;
        }
    }

    for (int i = 0; g_db_whitelist[i]; i++) {
        const char *pat = g_db_whitelist[i];
        size_t plen = strlen(pat);
        size_t nlen = strlen(name);
        if (pat[0] == 'M' && plen <= nlen && strncmp(name, pat, plen) == 0)
            return 1;  /* MANIFEST- 前缀匹配 */
        if (plen <= nlen && strcasecmp(name + nlen - plen, pat) == 0)
            return 1;  /* 后缀匹配 */
    }
    return 0;
}

/* ============================================================
 *  fd 管理表
 * ============================================================ */
#define MAX_FD 65536

typedef struct {
    int refcount;          /* duplicated fds share one open-file description */
    int active;
    int has_header;
    int is_compressed;
    int open_flags;
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
    /* block cache：缓存最近读取的一个 block，加速小块随机读 */
    uint32_t cache_block_id;
    uint8_t *cache_buf;
    int cache_valid;
    /* 延迟 header 写入：open 时标记 pending，首次 write/close 时实际写入 */
    int header_pending;
} fd_info_t;

static fd_info_t *g_fd_table[MAX_FD];
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void release_fd_info_locked(fd_info_t *info) {
    if (!info) return;
    if (--info->refcount > 0) return;
    free(info->blocks);
    free(info->ra_buf);
    free(info->cache_buf);
    free(info);
}

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
    release_fd_info_locked(g_fd_table[fd]);
    if (info && info->refcount <= 0) info->refcount = 1;
    g_fd_table[fd] = info;
    pthread_mutex_unlock(&g_lock);
}

static void share_fd_info(int oldfd, int newfd) {
    if (oldfd < 0 || oldfd >= MAX_FD || newfd < 0 || newfd >= MAX_FD) return;
    pthread_mutex_lock(&g_lock);
    fd_info_t *info = g_fd_table[oldfd];
    if (info) {
        info->refcount++;
        g_fd_table[newfd] = info;
    }
    pthread_mutex_unlock(&g_lock);
}

static void clear_fd_info(int fd) {
    if (fd < 0 || fd >= MAX_FD) return;
    pthread_mutex_lock(&g_lock);
    release_fd_info_locked(g_fd_table[fd]);
    g_fd_table[fd] = NULL;
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
        if (n >= 0) errno = EIO;
        return -1;
    }
    if (!gpuc_is_header(&hdr)) {
        errno = saved_errno;
        return 1; /* ordinary non-GPUC file */
    }
    off64_t phys_size = get_phys_size(fd);
    if (hdr.block_size != GPUC_BLOCK_SIZE ||
        hdr.num_blocks > GPUC_MAX_BLOCKS ||
        hdr.header_size < sizeof(hdr) ||
        hdr.header_size > (uint64_t)phys_size) {
        errno = EINVAL;
        return -1;
    }
    if (hdr.state == GPUC_STATE_COMPRESSED) {
        uint32_t expected_blocks = gpuc_num_blocks(hdr.orig_size);
        if (hdr.orig_size == 0 || hdr.num_blocks == 0 ||
            hdr.num_blocks != expected_blocks) {
            errno = EINVAL;
            return -1;
        }
    } else if (hdr.state == GPUC_STATE_INLINE) {
        if (hdr.orig_size > GPUC_INLINE_THRESHOLD || hdr.num_blocks != 0 ||
            hdr.header_size != sizeof(hdr) + hdr.orig_size) {
            errno = EINVAL;
            return -1;
        }
    } else if (hdr.state == GPUC_STATE_RAW) {
        if (hdr.header_size != sizeof(hdr)) {
            errno = EINVAL;
            return -1;
        }
    } else {
        errno = EINVAL;
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
            if (dst->orig_len == 0 || dst->orig_len > GPUC_BLOCK_SIZE ||
                dst->comp_len == 0 ||
                dst->comp_len > GC_NCHUNKS * GC_SLOT_SIZE ||
                dst->offset < hdr.header_size ||
                dst->offset > (uint64_t)phys_size ||
                dst->comp_len > (uint64_t)phys_size - dst->offset) {
                free(block_buf);
                free(info->blocks);
                info->blocks = NULL;
                errno = EINVAL;
                return -1;
            }
        }
        free(block_buf);
    }
    errno = saved_errno;
    return 0;
}

static int probe_header(int fd, fd_info_t *info) {
    int ret = read_header(fd, info);
    int fd_flags = fcntl(fd, F_GETFL);
    if (ret < 0 && (errno == EBADF || (fd_flags >= 0 && (fd_flags & O_DIRECT)))) {
        char proc_path[64];
        snprintf(proc_path, sizeof(proc_path), "/proc/self/fd/%d", fd);
        int probe = real_open(proc_path, O_RDONLY);
        if (probe < 0) return -1;
        ret = read_header(probe, info);
        int saved = errno;
        real_close(probe);
        errno = saved;
    }
    return ret;
}

static int normalize_managed_fd_flags(int fd, fd_info_t *info) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) return -1;
    /*
     * GPUC's 56-byte RAW header and compact compressed block offsets are not
     * O_DIRECT aligned. Clear it for managed descriptors and expose this
     * limitation explicitly in experiments instead of silently reading the
     * physical format as if it were logical data.
     */
    if (flags & O_DIRECT) {
        if (fcntl(fd, F_SETFL, flags & ~O_DIRECT) != 0) return -1;
        info->open_flags &= ~O_DIRECT;
    }
    return 0;
}

static void discard_unregistered_fd_info(fd_info_t *info) {
    if (!info) return;
    free(info->blocks);
    free(info->ra_buf);
    free(info->cache_buf);
    free(info);
}

static int write_raw_header(int fd, fd_info_t *info) {
    struct gpuc_header hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic = GPUC_MAGIC;
    hdr.version = GPUC_VERSION;
    hdr.block_size = GPUC_BLOCK_SIZE;
    hdr.state = GPUC_STATE_RAW;
    const char *algo_env = getenv("GPUC_ALGO");
    hdr.comp_algo = (algo_env && strcmp(algo_env, "lz4") == 0) ? GPUC_ALGO_LZ4 : GPUC_ALGO_SGLZ;
    hdr.header_size = sizeof(hdr);
    hdr.mtime = 0;
    hdr.ctime = 0;

    info->hdr = hdr;
    info->has_header = 1;
    info->is_compressed = 0;

    ssize_t n = real_write(fd, &hdr, sizeof(hdr));
    if (n != (ssize_t)sizeof(hdr)) return -1;
    info->header_pending = 0;
    return 0;
}

/* 延迟写入 pending 的 RAW header */
static int flush_raw_header(int fd, fd_info_t *info) {
    if (!info->header_pending) return 0;
    ssize_t n = real_write(fd, &info->hdr, sizeof(info->hdr));
    if (n != (ssize_t)sizeof(info->hdr)) return -1;
    info->header_pending = 0;
    return 0;
}

static off64_t get_logical_size(fd_info_t *info) {
    if (!info->has_header) return info->phys_size;
    if (info->is_compressed) return (off64_t)info->hdr.orig_size;
    if (info->header_pending) return info->phys_size;  /* header 尚未写入，逻辑大小等于物理大小 */
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

/* 支持编译时覆盖：make ABLATION_FLAGS="-DMAX_BATCH_BLOCKS=8" */
#ifndef MAX_BATCH_BLOCKS
#ifdef GPUC_NO_BATCH
#define MAX_BATCH_BLOCKS 1
#else
#define MAX_BATCH_BLOCKS 4
#endif
#endif

static __thread uint8_t *g_tls_batch_comp_bufs = NULL;
static __thread uint8_t *g_tls_batch_decomp_bufs = NULL;
static __thread uint8_t **g_tls_batch_in_ptrs = NULL;
static __thread uint8_t **g_tls_batch_out_ptrs = NULL;
static __thread size_t *g_tls_batch_in_lens = NULL;
static __thread size_t *g_tls_batch_out_lens = NULL;

static int ensure_batch_tls_buffers(void) {
    if (!g_tls_batch_comp_bufs) {
        tls_alloc(g_tls_batch_comp_bufs, TLS_BATCH_CAPACITY * GC_NCHUNKS * GC_SLOT_SIZE);
        if (!g_tls_batch_comp_bufs) return -1;
    }
    if (!g_tls_batch_decomp_bufs) {
        tls_alloc(g_tls_batch_decomp_bufs, TLS_BATCH_CAPACITY * GPUC_BLOCK_SIZE);
        if (!g_tls_batch_decomp_bufs) return -1;
    }
    if (!g_tls_batch_in_ptrs) {
        g_tls_batch_in_ptrs = (uint8_t **)malloc(TLS_BATCH_CAPACITY * sizeof(uint8_t *));
        if (!g_tls_batch_in_ptrs) return -1;
    }
    if (!g_tls_batch_out_ptrs) {
        g_tls_batch_out_ptrs = (uint8_t **)malloc(TLS_BATCH_CAPACITY * sizeof(uint8_t *));
        if (!g_tls_batch_out_ptrs) return -1;
    }
    if (!g_tls_batch_in_lens) {
        g_tls_batch_in_lens = (size_t *)malloc(TLS_BATCH_CAPACITY * sizeof(size_t));
        if (!g_tls_batch_in_lens) return -1;
    }
    if (!g_tls_batch_out_lens) {
        g_tls_batch_out_lens = (size_t *)malloc(TLS_BATCH_CAPACITY * sizeof(size_t));
        if (!g_tls_batch_out_lens) return -1;
    }
    return 0;
}

/* ============================================================
 *  双缓冲流水线 TLS（overlap I/O with GPU compute）
 * ============================================================ */

#ifdef GPUC_NO_PIPELINE
#define NUM_PIPELINES 1
#else
#define NUM_PIPELINES 2
#endif

/* 多 CUDA Stream 并发：每个线程分配 2 个独立 stream（双缓冲） */
#define MAX_TOTAL_STREAMS 64
static volatile int g_next_stream_base = 0;
static __thread int g_tls_stream_base = -1;

static int get_stream_id(int pipe_id) {
    if (g_tls_stream_base < 0) {
        int base = __sync_fetch_and_add(&g_next_stream_base, NUM_PIPELINES);
        g_tls_stream_base = base % MAX_TOTAL_STREAMS;
    }
    return (g_tls_stream_base + pipe_id) % MAX_TOTAL_STREAMS;
}

static __thread uint8_t *g_tls_pipe_comp_bufs[NUM_PIPELINES] = {NULL};
static __thread uint8_t *g_tls_pipe_decomp_bufs[NUM_PIPELINES] = {NULL};
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
static __thread uint8_t *g_tls_iouring_raw_bufs[NUM_PIPELINES] = {NULL};

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
/* The ring is process-global. Keep each submit/drain transaction atomic so
 * concurrent application threads cannot overwrite SQEs or consume another
 * thread's CQEs. */
static pthread_mutex_t g_iouring_lock = PTHREAD_MUTEX_INITIALIZER;

static int gpuc_iouring_init(unsigned int entries) {
    if (g_iouring.initialized) return 0;
#ifdef GPUC_NO_IOURING
    (void)entries;
    return -1;
#else
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
#endif
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

static int gpuc_iouring_flush_sq(int to_submit) {
    if (!g_iouring.initialized || to_submit <= 0) return 0;
    return syscall(__NR_io_uring_enter, g_iouring.ring_fd, (unsigned)to_submit, 0, 0, NULL, 0);
}

static int gpuc_iouring_sq_space(void) {
    if (!g_iouring.initialized) return 0;
    unsigned head = *g_iouring.sq_head;
    unsigned tail = *g_iouring.sq_tail;
    return (int)(g_iouring.sq_mask + 1 - (tail - head));
}

static int gpuc_iouring_submit_pread(int fd, void *buf, size_t len, off64_t off) {
    if (!g_iouring.initialized) return -1;
    /* 若 SQ 即将满，先 flush 已提交的请求，避免覆盖未完成的 SQE */
    if (gpuc_iouring_sq_space() < 2) {
        int flush = (int)(*g_iouring.sq_tail - *g_iouring.sq_head);
        if (gpuc_iouring_flush_sq(flush) < 0) return -1;
    }
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

static int gpuc_iouring_wait_all(int n, int *results, void *const *expected_bufs) {
    if (!g_iouring.initialized) return -1;
    int seen[MAX_BATCH_BLOCKS] = {0};
    int completed = 0;
    while (completed < n) {
        unsigned head = *g_iouring.cq_head;
        unsigned tail = *g_iouring.cq_tail;
        while (head != tail && completed < n) {
            struct io_uring_cqe *cqe = &g_iouring.cqes[head & g_iouring.cq_mask];
            int result_index = -1;
            for (int i = 0; i < n; i++) {
                if (!seen[i] && expected_bufs[i] == (void *)(uintptr_t)cqe->user_data) {
                    result_index = i;
                    break;
                }
            }
            if (result_index < 0) return -1;
            seen[result_index] = 1;
            if (results) results[result_index] = cqe->res;
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

static ssize_t read_compressed_lz4(int fd, fd_info_t *info, void *buf, size_t count);
static ssize_t read_compressed_at_lz4(int fd, fd_info_t *info, void *buf, size_t count, off64_t offset);

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

    if (info->hdr.comp_algo == GPUC_ALGO_LZ4) {
        return read_compressed_lz4(fd, info, buf, count);
    }

    ensure_backend_init();
#ifndef GPUC_NO_FALLBACK
    int use_cpu = should_cpu_fallback();
#else
    int use_cpu = 0;
#endif
    decomp_async_fn_t decomp_async = use_cpu ? cpu_decompress_batch_compact_async : g_backend_decompress_batch_compact_async;
    decomp_wait_fn_t  decomp_wait  = use_cpu ? cpu_decompress_batch_compact_wait  : g_backend_decompress_batch_compact_wait;
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
#ifdef GPUC_NO_READAHEAD
    (void)first_block;
    info->seq_count = 0;
    info->ra_max_blocks = 0;
#else
    if (info->last_read_block > 0 &&
        (first_block == info->last_read_block || first_block == info->last_read_block + 1)) {
        info->seq_count++;
        if (info->seq_count >= 4) info->ra_max_blocks = MAX_BATCH_BLOCKS;
        else if (info->seq_count >= 2) info->ra_max_blocks = 8;
        else if (info->seq_count >= 1) info->ra_max_blocks = 4;
        else info->ra_max_blocks = 0;
    } else {
        info->seq_count = 0;
        info->ra_max_blocks = 0;
    }
#endif

    /* ---- block cache：单 block 随机读加速 ---- */
    {
        uint32_t last_block_cache = (uint32_t)((start + count - 1) / GPUC_BLOCK_SIZE);
        if (first_block == last_block_cache && info->cache_valid && info->cache_block_id == first_block) {
            off64_t block_off = start % GPUC_BLOCK_SIZE;
            size_t to_copy = GPUC_BLOCK_SIZE - (size_t)block_off;
            if (to_copy > count) to_copy = count;
            memcpy(out_ptr, info->cache_buf + block_off, to_copy);
            info->cur_offset = start + (off64_t)to_copy;
            return (ssize_t)to_copy;
        }
    }

    int pipe_id = 0;
    int has_submitted = 0;
    off64_t orig_start = start;
    size_t orig_count = count;

    while (count > 0) {
        /* 如果有已提交的 batch，先消费它 */
        if (has_submitted) {
            int prev = (pipe_id + NUM_PIPELINES - 1) % NUM_PIPELINES;

            if (g_tls_pipe_n_compressed[prev] > 0) {
                decomp_wait(get_stream_id(prev),
                    g_tls_pipe_n_compressed[prev],
                    g_tls_pipe_out_ptrs[prev],
                    g_tls_pipe_out_lens[prev]);
            }

#ifndef GPUC_NO_VERIFY_CRC
            if (verify_batch_crc(info, prev, g_tls_pipe_first_block[prev],
                                 g_tls_pipe_nblocks[prev]) != 0) {
                return (total_read > 0) ? (ssize_t)total_read : -1;
            }
#endif

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

        /* 消费后再计算当前 batch 的参数 */
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
        if (decompress_nblocks > MAX_BATCH_BLOCKS) decompress_nblocks = MAX_BATCH_BLOCKS;

        /* 准备当前 batch（CPU pread / io_uring，与上一个 batch 的 GPU 解压重叠） */
        g_tls_pipe_first_block[pipe_id] = first_block;
        g_tls_pipe_first_block_off[pipe_id] = first_block_off;
        g_tls_pipe_user_nblocks[pipe_id] = user_nblocks;
        g_tls_pipe_nblocks[pipe_id] = decompress_nblocks;
        g_tls_pipe_n_compressed[pipe_id] = 0;
        g_tls_pipe_total_compact_len[pipe_id] = 0;

        int use_iouring = g_iouring.initialized;
        if (use_iouring) {
            void *iouring_bufs[MAX_BATCH_BLOCKS];
            pthread_mutex_lock(&g_iouring_lock);
            for (int i = 0; i < decompress_nblocks; i++) {
                uint32_t bid = first_block + i;
                struct gpuc_block_entry *be = &info->blocks[bid];
                uint8_t *read_buf = (be->comp_len == be->orig_len)
                    ? g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE
                    : g_tls_iouring_raw_bufs[pipe_id] + i * GPUC_BLOCK_SIZE;
                iouring_bufs[i] = read_buf;
                if (gpuc_iouring_submit_pread(fd, read_buf, be->comp_len,
                                             (off64_t)be->offset) < 0) {
                    use_iouring = 0;
                    break;
                }
            }
            if (use_iouring && gpuc_iouring_enter_wait(decompress_nblocks, 0) < 0) {
                use_iouring = 0;  /* 提交失败，fallback */
            } else if (use_iouring) {
                int iouring_results[MAX_BATCH_BLOCKS];
                if (gpuc_iouring_wait_all(decompress_nblocks, iouring_results,
                                          iouring_bufs) < 0) {
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
            pthread_mutex_unlock(&g_iouring_lock);
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
            if (decomp_async) {
                decomp_async(
                    g_tls_pipe_n_compressed[pipe_id],
                    g_tls_pipe_comp_bufs[pipe_id], g_tls_pipe_total_compact_len[pipe_id],
                    g_tls_pipe_chunk_offsets[pipe_id],
                    g_tls_pipe_out_lens[pipe_id],
                    get_stream_id(pipe_id));
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
        pipe_id = (pipe_id + 1) % NUM_PIPELINES;
    }

    /* 处理最后一个已提交但未消费的 batch */
    if (has_submitted) {
        int last = (pipe_id + NUM_PIPELINES - 1) % NUM_PIPELINES;
        if (g_tls_pipe_n_compressed[last] > 0) {
            decomp_wait(get_stream_id(last),
                g_tls_pipe_n_compressed[last],
                g_tls_pipe_out_ptrs[last],
                g_tls_pipe_out_lens[last]);
        }
#ifndef GPUC_NO_VERIFY_CRC
        if (verify_batch_crc(info, last, g_tls_pipe_first_block[last],
                             g_tls_pipe_nblocks[last]) != 0) {
            return (total_read > 0) ? (ssize_t)total_read : -1;
        }
#endif
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

    /* block cache：单 block 读取时缓存结果 */
    if (has_submitted) {
        int last_pipe = (pipe_id + NUM_PIPELINES - 1) % NUM_PIPELINES;
        uint32_t last_block = (uint32_t)((orig_start + orig_count - 1) / GPUC_BLOCK_SIZE);
        if (first_block == last_block && g_tls_pipe_user_nblocks[last_pipe] > 0) {
            if (!info->cache_buf) {
                info->cache_buf = (uint8_t *)malloc(GPUC_BLOCK_SIZE);
            }
            if (info->cache_buf) {
                info->cache_block_id = first_block;
                memcpy(info->cache_buf,
                       g_tls_pipe_decomp_bufs[last_pipe] + (first_block - g_tls_pipe_first_block[last_pipe]) * GPUC_BLOCK_SIZE,
                       GPUC_BLOCK_SIZE);
                info->cache_valid = 1;
            }
        }
    }

    info->last_read_block = (uint32_t)((orig_start + orig_count - 1) / GPUC_BLOCK_SIZE);
    info->cur_offset = start;
    return (ssize_t)total_read;
}

/* ============================================================
 *  LZ4 compressed read path
 *
 *  nvCOMP has high per-launch overhead. Decompress up to MAX_BATCH_BLOCKS
 *  consecutive blocks in one call and retain the logical result as read-ahead.
 * ============================================================ */

static int fill_lz4_readahead(int fd, fd_info_t *info, uint32_t first_block,
                              int use_cpu) {
    if (ensure_batch_tls_buffers() != 0) {
        errno = ENOMEM;
        return -1;
    }
    if (!info->ra_buf) {
        info->ra_buf = (uint8_t *)malloc(LZ4_BATCH_BLOCKS * GPUC_BLOCK_SIZE);
        if (!info->ra_buf) {
            errno = ENOMEM;
            return -1;
        }
    }

    uint32_t remaining = info->hdr.num_blocks - first_block;
    int nblocks = remaining < LZ4_BATCH_BLOCKS ? (int)remaining : LZ4_BATCH_BLOCKS;
    int ncompressed = 0;
    size_t logical_len = 0;
    const size_t input_stride = GC_NCHUNKS * GC_SLOT_SIZE;

    for (int i = 0; i < nblocks; i++) {
        struct gpuc_block_entry *be = &info->blocks[first_block + (uint32_t)i];
        uint8_t *out = info->ra_buf + logical_len;
        if (be->comp_len == be->orig_len) {
            ssize_t nr = real_pread64(fd, out, be->comp_len, (off64_t)be->offset);
            if (nr != (ssize_t)be->comp_len) return -1;
        } else {
            uint8_t *in = g_tls_batch_comp_bufs + (size_t)ncompressed * input_stride;
            ssize_t nr = real_pread64(fd, in, be->comp_len, (off64_t)be->offset);
            if (nr != (ssize_t)be->comp_len) return -1;
            g_tls_batch_in_ptrs[ncompressed] = in;
            g_tls_batch_in_lens[ncompressed] = be->comp_len;
            g_tls_batch_out_ptrs[ncompressed] = out;
            g_tls_batch_out_lens[ncompressed] = be->orig_len;
            ncompressed++;
        }
        logical_len += be->orig_len;
    }

    if (ncompressed > 0) {
        int ret = use_cpu
            ? cpu_lz4_decompress_batch(ncompressed,
                                       (const uint8_t **)g_tls_batch_in_ptrs,
                                       g_tls_batch_in_lens, g_tls_batch_out_ptrs,
                                       g_tls_batch_out_lens)
            : gpu_lz4_decompress_batch(ncompressed,
                                       (const uint8_t **)g_tls_batch_in_ptrs,
                                       g_tls_batch_in_lens, g_tls_batch_out_ptrs,
                                       g_tls_batch_out_lens);
        if (ret != ncompressed) {
            fprintf(stderr, "[HOOK] LZ4 batch decompress failed at block %u\n",
                    first_block);
            errno = EIO;
            return -1;
        }
    }

#ifndef GPUC_NO_VERIFY_CRC
    size_t block_offset = 0;
    for (int i = 0; i < nblocks; i++) {
        struct gpuc_block_entry *be = &info->blocks[first_block + (uint32_t)i];
        if (be->crc32 != 0 &&
            gpuc_crc32(info->ra_buf + block_offset, be->orig_len) != be->crc32) {
            fprintf(stderr, "[HOOK] LZ4 CRC32 mismatch at block %u\n",
                    first_block + (uint32_t)i);
            errno = EIO;
            return -1;
        }
        block_offset += be->orig_len;
    }
#endif

    info->ra_start_offset = (off64_t)first_block * GPUC_BLOCK_SIZE;
    info->ra_valid_len = logical_len;
    info->ra_active = 1;
    return 0;
}

static ssize_t read_compressed_at_lz4(int fd, fd_info_t *info, void *buf,
                                      size_t count, off64_t offset) {
    ensure_backend_init();
#ifndef GPUC_NO_FALLBACK
    int use_cpu = should_cpu_fallback();
#else
    int use_cpu = 0;
#endif
    off64_t start = offset;
    off64_t log_size = get_logical_size(info);
    if (start >= log_size) return 0;
    if (start + (off64_t)count > log_size)
        count = (size_t)(log_size - start);

    uint8_t *out_ptr = (uint8_t *)buf;
    size_t total_read = 0;

    while (count > 0) {
        off64_t ra_end = info->ra_start_offset + (off64_t)info->ra_valid_len;
        if (!info->ra_active || start < info->ra_start_offset || start >= ra_end) {
            uint32_t block_id = (uint32_t)(start / GPUC_BLOCK_SIZE);
            if (block_id >= info->hdr.num_blocks ||
                fill_lz4_readahead(fd, info, block_id, use_cpu) != 0)
                return total_read > 0 ? (ssize_t)total_read : -1;
            ra_end = info->ra_start_offset + (off64_t)info->ra_valid_len;
        }

        size_t ra_offset = (size_t)(start - info->ra_start_offset);
        size_t to_copy = (size_t)(ra_end - start);
        if (to_copy > count) to_copy = count;
        memcpy(out_ptr, info->ra_buf + ra_offset, to_copy);
        out_ptr += to_copy;
        start += to_copy;
        count -= to_copy;
        total_read += to_copy;
    }

    return (ssize_t)total_read;
}

static ssize_t read_compressed_lz4(int fd, fd_info_t *info, void *buf,
                                   size_t count) {
    ssize_t ret = read_compressed_at_lz4(fd, info, buf, count, info->cur_offset);
    if (ret > 0) info->cur_offset += ret;
    return ret;
}

/* ============================================================
 *  RAW 文件的 read 路径（跳过 header）
 * ============================================================ */

static ssize_t read_raw(int fd, fd_info_t *info, void *buf, size_t count) {
    off64_t log_size = get_logical_size(info);
    if (info->cur_offset >= log_size) return 0;
    if (info->cur_offset + (off64_t)count > log_size)
        count = (size_t)(log_size - info->cur_offset);

    off64_t phys_off = info->cur_offset + (info->header_pending ? 0 : (off64_t)info->hdr.header_size);
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

    if (info->hdr.comp_algo == GPUC_ALGO_LZ4) {
        return read_compressed_at_lz4(fd, info, buf, count, offset);
    }

    ensure_backend_init();
#ifndef GPUC_NO_FALLBACK
    int use_cpu = should_cpu_fallback();
#else
    int use_cpu = 0;
#endif
    decomp_async_fn_t decomp_async = use_cpu ? cpu_decompress_batch_compact_async : g_backend_decompress_batch_compact_async;
    decomp_wait_fn_t  decomp_wait  = use_cpu ? cpu_decompress_batch_compact_wait  : g_backend_decompress_batch_compact_wait;
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

    /* ---- block cache：单 block 随机读加速 ---- */
    uint32_t first_block_at = (uint32_t)(start / GPUC_BLOCK_SIZE);
    uint32_t last_block_at = (uint32_t)((start + count - 1) / GPUC_BLOCK_SIZE);
    if (first_block_at == last_block_at && info->cache_valid && info->cache_block_id == first_block_at) {
        off64_t block_off = start % GPUC_BLOCK_SIZE;
        size_t to_copy = GPUC_BLOCK_SIZE - (size_t)block_off;
        if (to_copy > count) to_copy = count;
        memcpy(out_ptr, info->cache_buf + block_off, to_copy);
        return (ssize_t)to_copy;
    }

    int pipe_id = 0;
    int has_submitted = 0;

    while (count > 0) {
        /* 消费上一个已提交的 batch */
        if (has_submitted) {
            int prev = (pipe_id + NUM_PIPELINES - 1) % NUM_PIPELINES;

            if (g_tls_pipe_n_compressed[prev] > 0) {
                decomp_wait(get_stream_id(prev),
                    g_tls_pipe_n_compressed[prev],
                    g_tls_pipe_out_ptrs[prev],
                    g_tls_pipe_out_lens[prev]);
            }

#ifndef GPUC_NO_VERIFY_CRC
            if (verify_batch_crc(info, prev, g_tls_pipe_first_block[prev],
                                 g_tls_pipe_nblocks[prev]) != 0) {
                return (total_read > 0) ? (ssize_t)total_read : -1;
            }
#endif

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

        /* 消费后再计算当前 batch 的参数 */
        uint32_t first_block = (uint32_t)(start / GPUC_BLOCK_SIZE);
        off64_t first_block_off = start % GPUC_BLOCK_SIZE;
        if (first_block >= info->hdr.num_blocks) break;

        uint32_t last_block = (uint32_t)((start + count - 1) / GPUC_BLOCK_SIZE);
        if (last_block >= info->hdr.num_blocks) last_block = info->hdr.num_blocks - 1;
        int nblocks = (int)(last_block - first_block + 1);
        if (nblocks > MAX_BATCH_BLOCKS) nblocks = MAX_BATCH_BLOCKS;

        /* 准备当前 batch（io_uring / pread64） */
        g_tls_pipe_first_block[pipe_id] = first_block;
        g_tls_pipe_first_block_off[pipe_id] = first_block_off;
        g_tls_pipe_user_nblocks[pipe_id] = nblocks;
        g_tls_pipe_nblocks[pipe_id] = nblocks;
        g_tls_pipe_n_compressed[pipe_id] = 0;
        g_tls_pipe_total_compact_len[pipe_id] = 0;

        int use_iouring = g_iouring.initialized;
        if (use_iouring) {
            void *iouring_bufs[MAX_BATCH_BLOCKS];
            pthread_mutex_lock(&g_iouring_lock);
            for (int i = 0; i < nblocks; i++) {
                uint32_t bid = first_block + i;
                struct gpuc_block_entry *be = &info->blocks[bid];
                uint8_t *read_buf = (be->comp_len == be->orig_len)
                    ? g_tls_pipe_decomp_bufs[pipe_id] + i * GPUC_BLOCK_SIZE
                    : g_tls_iouring_raw_bufs[pipe_id] + i * GPUC_BLOCK_SIZE;
                iouring_bufs[i] = read_buf;
                if (gpuc_iouring_submit_pread(fd, read_buf, be->comp_len,
                                             (off64_t)be->offset) < 0) {
                    use_iouring = 0;
                    break;
                }
            }
            if (use_iouring && gpuc_iouring_enter_wait(nblocks, 0) < 0) {
                use_iouring = 0;
            } else if (use_iouring) {
                int iouring_results[MAX_BATCH_BLOCKS];
                if (gpuc_iouring_wait_all(nblocks, iouring_results,
                                          iouring_bufs) < 0) {
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
            pthread_mutex_unlock(&g_iouring_lock);
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

        /* 提交当前 batch GPU async */
        if (g_tls_pipe_n_compressed[pipe_id] > 0) {
            if (decomp_async) {
                decomp_async(
                    g_tls_pipe_n_compressed[pipe_id],
                    g_tls_pipe_comp_bufs[pipe_id], g_tls_pipe_total_compact_len[pipe_id],
                    g_tls_pipe_chunk_offsets[pipe_id],
                    g_tls_pipe_out_lens[pipe_id],
                    get_stream_id(pipe_id));
            } else if (g_backend_decompress_batch_compact) {
                g_backend_decompress_batch_compact(
                    g_tls_pipe_n_compressed[pipe_id],
                    g_tls_pipe_comp_bufs[pipe_id], g_tls_pipe_total_compact_len[pipe_id],
                    g_tls_pipe_chunk_offsets[pipe_id],
                    g_tls_pipe_out_ptrs[pipe_id], g_tls_pipe_out_lens[pipe_id]);
            }
        }

        has_submitted = 1;
        pipe_id = (pipe_id + 1) % NUM_PIPELINES;
    }

    /* 处理最后一个 batch */
    if (has_submitted) {
        int last = (pipe_id + NUM_PIPELINES - 1) % NUM_PIPELINES;
        if (g_tls_pipe_n_compressed[last] > 0) {
            decomp_wait(get_stream_id(last),
                g_tls_pipe_n_compressed[last],
                g_tls_pipe_out_ptrs[last],
                g_tls_pipe_out_lens[last]);
        }
#ifndef GPUC_NO_VERIFY_CRC
        if (verify_batch_crc(info, last, g_tls_pipe_first_block[last],
                             g_tls_pipe_nblocks[last]) != 0) {
            return (total_read > 0) ? (ssize_t)total_read : -1;
        }
#endif
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

    /* block cache：单 block 读取时缓存结果 */
    if (has_submitted) {
        int last_pipe = (pipe_id + NUM_PIPELINES - 1) % NUM_PIPELINES;
        if (first_block_at == last_block_at && g_tls_pipe_user_nblocks[last_pipe] > 0) {
            if (!info->cache_buf) {
                info->cache_buf = (uint8_t *)malloc(GPUC_BLOCK_SIZE);
            }
            if (info->cache_buf) {
                info->cache_block_id = first_block_at;
                memcpy(info->cache_buf,
                       g_tls_pipe_decomp_bufs[last_pipe] + (first_block_at - g_tls_pipe_first_block[last_pipe]) * GPUC_BLOCK_SIZE,
                       GPUC_BLOCK_SIZE);
                info->cache_valid = 1;
            }
        }
    }

    return (ssize_t)total_read;
}


/* ============================================================
 *  构造函数 / 析构函数
 * ============================================================ */

void __attribute__((constructor(101))) hook_init(void) {
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
    real_rename    = dlsym(RTLD_NEXT, "rename");
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
    if (!real_rename)    fprintf(stderr, "[HOOK] WARN: dlsym(rename) failed\n");
    if (!real_dup)       fprintf(stderr, "[HOOK] WARN: dlsym(dup) failed\n");
    if (!real_dup2)      fprintf(stderr, "[HOOK] WARN: dlsym(dup2) failed\n");
    if (!real_dup3)      fprintf(stderr, "[HOOK] WARN: dlsym(dup3) failed\n");
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
        /*
         * 不在后台线程并发初始化 CUDA。旧实现可能与第一次 I/O 的
         * pthread_once 路径同时进入 gpu_compress_init()，竞争全局内存池。
         * 当前统一由 ensure_backend_init() 串行 lazy-init。
         */
    }
#endif

    /* 初始化 io_uring（批量异步 I/O），失败静默 fallback 到 pread64 */
    int iouring_depth = 128;
    const char *iouring_depth_env = getenv("GPUC_IOURING_DEPTH");
    if (iouring_depth_env) {
        int env_depth = atoi(iouring_depth_env);
        if (env_depth >= 16 && env_depth <= 4096) iouring_depth = env_depth;
    }
    if (gpuc_iouring_init((unsigned)iouring_depth) == 0) {
        if (!quiet) fprintf(stderr, "[HOOK] io_uring: async I/O enabled (depth=%d)\n", iouring_depth);
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
    if (is_whitelisted_path(pathname)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    if (!info) { real_close(fd); errno = ENOMEM; return -1; }
    info->active = 1;
    info->open_flags = flags;
    info->phys_size = get_phys_size(fd);

    if (info->phys_size == 0) {
        /* 延迟写入 header：只初始化结构体，等首次 write/close 时实际写入 */
        struct gpuc_header hdr;
        memset(&hdr, 0, sizeof(hdr));
        hdr.magic = GPUC_MAGIC;
        hdr.version = GPUC_VERSION;
        hdr.block_size = GPUC_BLOCK_SIZE;
        hdr.state = GPUC_STATE_RAW;
        const char *algo_env2 = getenv("GPUC_ALGO");
        hdr.comp_algo = (algo_env2 && strcmp(algo_env2, "lz4") == 0) ? GPUC_ALGO_LZ4 : GPUC_ALGO_SGLZ;
        hdr.header_size = sizeof(hdr);
        info->hdr = hdr;
        info->has_header = 1;
        info->is_compressed = 0;
        info->header_pending = 1;
    } else if (info->phys_size >= (off64_t)sizeof(struct gpuc_header)) {
        if (probe_header(fd, info) < 0) {
            int saved = errno;
            discard_unregistered_fd_info(info);
            real_close(fd);
            errno = saved;
            return -1;
        }
    }

    if (info->has_header && normalize_managed_fd_flags(fd, info) != 0) {
        int saved = errno;
        discard_unregistered_fd_info(info);
        real_close(fd);
        errno = saved;
        return -1;
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
    if (is_whitelisted_path(pathname)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    if (!info) { real_close(fd); errno = ENOMEM; return -1; }
    info->active = 1;
    info->open_flags = flags;
    info->phys_size = get_phys_size(fd);

    if (info->phys_size == 0) {
        if (normalize_managed_fd_flags(fd, info) != 0) {
            int saved = errno;
            discard_unregistered_fd_info(info);
            real_close(fd);
            errno = saved;
            return -1;
        }
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    } else if (info->phys_size >= (off64_t)sizeof(struct gpuc_header)) {
        if (probe_header(fd, info) < 0) {
            int saved = errno;
            discard_unregistered_fd_info(info);
            real_close(fd);
            errno = saved;
            return -1;
        }
    }

    if (info->has_header && normalize_managed_fd_flags(fd, info) != 0) {
        int saved = errno;
        discard_unregistered_fd_info(info);
        real_close(fd);
        errno = saved;
        return -1;
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
    if (is_whitelisted_path(pathname)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    if (!info) { real_close(fd); errno = ENOMEM; return -1; }
    info->active = 1;
    info->open_flags = O_WRONLY | O_CREAT | O_TRUNC;
    info->phys_size = get_phys_size(fd);

    if (info->phys_size == 0) {
        if (normalize_managed_fd_flags(fd, info) != 0) {
            int saved = errno;
            discard_unregistered_fd_info(info);
            real_close(fd);
            errno = saved;
            return -1;
        }
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    }

    if (info->has_header && normalize_managed_fd_flags(fd, info) != 0) {
        int saved = errno;
        discard_unregistered_fd_info(info);
        real_close(fd);
        errno = saved;
        return -1;
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

    /* 延迟 header 写入：首次 write 时先写入 pending 的 header */
    if (info->header_pending) {
        if (flush_raw_header(fd, info) != 0) {
            errno = EIO;
            return -1;
        }
    }

    ssize_t ret;
    if (info->open_flags & O_APPEND) {
        off64_t logical_end = get_phys_size(fd) - (off64_t)info->hdr.header_size;
        ret = real_write(fd, buf, count);
        if (ret > 0) info->cur_offset = logical_end + ret;
    } else {
        off64_t phys_off = info->cur_offset + (off64_t)info->hdr.header_size;
        ret = real_pwrite64(fd, buf, count, phys_off);
    }
    if (ret > 0) {
        if (!(info->open_flags & O_APPEND)) info->cur_offset += ret;
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
    off64_t phys_off = new_off + (info->header_pending ? 0 : (off64_t)info->hdr.header_size);
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

    off64_t phys_off = new_off + (info->header_pending ? 0 : (off64_t)info->hdr.header_size);
    real_lseek64(fd, phys_off, SEEK_SET);

    return new_off;
}

int close(int fd) {
    if (g_hooks_disabled) {
        if (!real_close) { errno = EBADF; return -1; }
        return real_close(fd);
    }
    fd_info_t *info = get_fd_info(fd);
    if (info && info->header_pending) {
        flush_raw_header(fd, info);
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
    if (info->is_compressed) {
        errno = EROFS;
        return -1;
    }
    if (info->header_pending && flush_raw_header(fd, info) != 0) {
        errno = EIO;
        return -1;
    }
    off_t phys_len = length + (off_t)info->hdr.header_size;
    int ret = real_ftruncate(fd, phys_len);
    if (ret == 0) info->phys_size = phys_len;
    return ret;
}

int truncate(const char *path, off_t length) {
    if (g_hooks_disabled) {
        if (!real_truncate) { errno = ENOSYS; return -1; }
        return real_truncate(path, length);
    }
    /* 直接读取 header；real_open() 创建的 fd 不会出现在 Hook fd 表中。 */
    int fd = real_open(path, O_RDONLY);
    if (fd >= 0) {
        struct gpuc_header hdr;
        ssize_t n = real_pread64(fd, &hdr, sizeof(hdr), 0);
        if (n == (ssize_t)sizeof(hdr) && gpuc_is_header(&hdr)) {
            real_close(fd);
            if (hdr.state == GPUC_STATE_COMPRESSED || hdr.state == GPUC_STATE_INLINE) {
                errno = EROFS;
                return -1;
            }
            return real_truncate(path, length + (off_t)hdr.header_size);
        }
        real_close(fd);
    }
    return real_truncate(path, length);
}

/* ============================================================
 *  rename 拦截：当目标路径是数据库白名单时，避免把 GPUC header 带过去
 *  典型场景：LevelDB 写临时文件 *.dbtmp 再 rename 为 CURRENT
 * ============================================================ */

static int copy_fd_xattrs(int srcfd, int dstfd) {
    ssize_t names_len = flistxattr(srcfd, NULL, 0);
    if (names_len <= 0) return names_len < 0 && errno != ENOTSUP ? -1 : 0;
    char *names = (char *)malloc((size_t)names_len);
    if (!names) return -1;
    if (flistxattr(srcfd, names, (size_t)names_len) != names_len) {
        free(names);
        return -1;
    }
    for (char *name = names; name < names + names_len; name += strlen(name) + 1) {
        ssize_t value_len = fgetxattr(srcfd, name, NULL, 0);
        if (value_len < 0) { free(names); return -1; }
        void *value = malloc(value_len ? (size_t)value_len : 1);
        if (!value) { free(names); return -1; }
        if (fgetxattr(srcfd, name, value, (size_t)value_len) != value_len ||
            fsetxattr(dstfd, name, value, (size_t)value_len, 0) != 0) {
            free(value);
            free(names);
            return -1;
        }
        free(value);
    }
    free(names);
    return 0;
}

static void fsync_parent_dir(const char *path) {
    char *copy = strdup(path);
    if (!copy) return;
    char *slash = strrchr(copy, '/');
    const char *dir = ".";
    if (slash) {
        if (slash == copy) slash[1] = '\0';
        else *slash = '\0';
        dir = copy;
    }
    int dfd = real_open(dir, O_RDONLY | O_DIRECTORY);
    if (dfd >= 0) {
        (void)fsync(dfd);
        real_close(dfd);
    }
    free(copy);
}

int rename(const char *oldpath, const char *newpath) {
    if (g_hooks_disabled) {
        if (!real_rename) { errno = ENOSYS; return -1; }
        return real_rename(oldpath, newpath);
    }
    if (!real_rename) { errno = ENOSYS; return -1; }

    /* 目标不是白名单，直接透传 */
    if (!is_whitelisted_path(newpath)) {
        return real_rename(oldpath, newpath);
    }

    /* 检查源文件是否带 GPUC header */
    int fd_src = real_open(oldpath, O_RDONLY);
    if (fd_src < 0) {
        return real_rename(oldpath, newpath);
    }

    struct gpuc_header hdr;
    ssize_t nr = real_read(fd_src, &hdr, sizeof(hdr));
    if (nr != (ssize_t)sizeof(hdr) || !gpuc_is_header(&hdr)) {
        real_close(fd_src);
        return real_rename(oldpath, newpath);
    }

    /* 安全起见：只对 RAW 状态文件做 header 剥离；
     * COMPRESSED 文件不应该出现在 rename 到白名单路径的场景。 */
    if (hdr.state != GPUC_STATE_RAW) {
        real_close(fd_src);
        return real_rename(oldpath, newpath);
    }

    /* 获取源文件权限 */
    struct stat64 st;
    if (fstat64(fd_src, &st) != 0) {
        real_close(fd_src);
        return real_rename(oldpath, newpath);
    }

    /* 在目标同目录写临时文件，完成并 fsync 后再原子替换目标。 */
    char tmp_path[4096];
    int fd_dst = -1;
    for (unsigned attempt = 0; attempt < 100 && fd_dst < 0; attempt++) {
        int n = snprintf(tmp_path, sizeof(tmp_path), "%s.gpucstrip.%ld.%u",
                         newpath, (long)getpid(), attempt);
        if (n < 0 || (size_t)n >= sizeof(tmp_path)) {
            errno = ENAMETOOLONG;
            break;
        }
        fd_dst = real_open(tmp_path, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 0777);
        if (fd_dst < 0 && errno != EEXIST) break;
    }
    if (fd_dst < 0) {
        real_close(fd_src);
        return -1;
    }

    if (real_lseek64(fd_src, (off64_t)hdr.header_size, SEEK_SET) < 0) {
        real_close(fd_src); real_close(fd_dst);
        syscall(SYS_unlink, tmp_path);
        return -1;
    }

    char buf[65536];
    while ((nr = real_read(fd_src, buf, sizeof(buf))) > 0) {
        if (real_write(fd_dst, buf, (size_t)nr) != nr) {
            real_close(fd_src); real_close(fd_dst);
            syscall(SYS_unlink, tmp_path);
            return -1;
        }
    }
    struct timespec rename_times[2] = {st.st_atim, st.st_mtim};
    if (nr < 0 ||
        fchmod(fd_dst, st.st_mode & 07777) != 0 ||
        (fchown(fd_dst, st.st_uid, st.st_gid) != 0 && errno != EPERM) ||
        copy_fd_xattrs(fd_src, fd_dst) != 0 ||
        futimens(fd_dst, rename_times) != 0 ||
        fsync(fd_dst) != 0) {
        int saved = errno;
        real_close(fd_src); real_close(fd_dst);
        syscall(SYS_unlink, tmp_path);
        errno = saved;
        return -1;
    }
    real_close(fd_src);
    real_close(fd_dst);

    if (real_rename(tmp_path, newpath) != 0) {
        int saved = errno;
        syscall(SYS_unlink, tmp_path);
        errno = saved;
        return -1;
    }
    fsync_parent_dir(newpath);
    syscall(SYS_unlink, oldpath);
    fsync_parent_dir(oldpath);
    return 0;
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
    if (newfd >= 0) share_fd_info(oldfd, newfd);
    return newfd;
}

int dup2(int oldfd, int newfd) {
    if (g_hooks_disabled) {
        if (!real_dup2) { errno = ENOSYS; return -1; }
        return real_dup2(oldfd, newfd);
    }
    if (oldfd == newfd) return real_dup2(oldfd, newfd);
    int ret = real_dup2(oldfd, newfd);
    if (ret >= 0) {
        clear_fd_info(newfd);
        share_fd_info(oldfd, newfd);
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
        share_fd_info(oldfd, newfd);
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
    if (info->is_compressed) {
        errno = EROFS;
        return -1;
    }
    if (info->header_pending) {
        if (flush_raw_header(fd, info) != 0) {
            errno = EIO;
            return -1;
        }
    }
    off64_t phys_off = offset + (off64_t)info->hdr.header_size;
    ssize_t ret = real_pwrite64(fd, buf, count, phys_off);
    if (ret > 0) info->phys_size = get_phys_size(fd);
    return ret;
}

/* pread / pwrite 别名（某些程序直接调用 pread 而非 pread64） */
ssize_t pread(int fd, void *buf, size_t count, off_t offset) {
    return pread64(fd, buf, count, (off64_t)offset);
}

ssize_t pwrite(int fd, const void *buf, size_t count, off_t offset) {
    return pwrite64(fd, buf, count, (off64_t)offset);
}

/*
 * With _FORTIFY_SOURCE, glibc may redirect pread/read to checked symbols.
 * Interpose those too; otherwise a fortified application can observe the
 * physical GPUC header even though the ordinary libc symbols are hooked.
 */
ssize_t __pread_chk(int fd, void *buf, size_t count, off_t offset, size_t buflen) {
    if (count > buflen) {
        errno = EOVERFLOW;
        return -1;
    }
    return pread(fd, buf, count, offset);
}

ssize_t __pread64_chk(int fd, void *buf, size_t count, off64_t offset, size_t buflen) {
    if (count > buflen) {
        errno = EOVERFLOW;
        return -1;
    }
    return pread64(fd, buf, count, offset);
}

ssize_t __read_chk(int fd, void *buf, size_t count, size_t buflen) {
    if (count > buflen) {
        errno = EOVERFLOW;
        return -1;
    }
    return read(fd, buf, count);
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
    /* RAW 也必须经过逻辑偏移转换，不能把 real_readv 的物理 offset 暴露给应用。 */
    ssize_t total = 0;
    for (int i = 0; i < iovcnt; i++) {
        ssize_t n = read(fd, iov[i].iov_base, iov[i].iov_len);
        if (n < 0) return total > 0 ? total : -1;
        total += n;
        if ((size_t)n < iov[i].iov_len) break;
    }
    return total;
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
    if (info->is_compressed) {
        errno = EROFS;
        return -1;
    }
    ssize_t total = 0;
    for (int i = 0; i < iovcnt; i++) {
        ssize_t n = write(fd, iov[i].iov_base, iov[i].iov_len);
        if (n < 0) return total > 0 ? total : -1;
        total += n;
        if ((size_t)n < iov[i].iov_len) break;
    }
    return total;
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
    if (is_whitelisted_path(pathname)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    if (!info) { real_close(fd); errno = ENOMEM; return -1; }
    info->active = 1;
    info->open_flags = flags;
    info->phys_size = get_phys_size(fd);
    if (info->phys_size == 0) {
        if (normalize_managed_fd_flags(fd, info) != 0) {
            int saved = errno;
            discard_unregistered_fd_info(info);
            real_close(fd);
            errno = saved;
            return -1;
        }
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    } else if (info->phys_size >= (off64_t)sizeof(struct gpuc_header)) {
        if (probe_header(fd, info) < 0) {
            int saved = errno;
            discard_unregistered_fd_info(info);
            real_close(fd);
            errno = saved;
            return -1;
        }
    }
    if (info->has_header && normalize_managed_fd_flags(fd, info) != 0) {
        int saved = errno;
        discard_unregistered_fd_info(info);
        real_close(fd);
        errno = saved;
        return -1;
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
    if (is_whitelisted_path(pathname)) return fd;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    if (!info) { real_close(fd); errno = ENOMEM; return -1; }
    info->active = 1;
    info->open_flags = flags;
    info->phys_size = get_phys_size(fd);
    if (info->phys_size == 0) {
        if (normalize_managed_fd_flags(fd, info) != 0) {
            int saved = errno;
            discard_unregistered_fd_info(info);
            real_close(fd);
            errno = saved;
            return -1;
        }
        write_raw_header(fd, info);
        info->phys_size = get_phys_size(fd);
    } else if (info->phys_size >= (off64_t)sizeof(struct gpuc_header)) {
        if (probe_header(fd, info) < 0) {
            int saved = errno;
            discard_unregistered_fd_info(info);
            real_close(fd);
            errno = saved;
            return -1;
        }
    }
    if (info->has_header && normalize_managed_fd_flags(fd, info) != 0) {
        int saved = errno;
        discard_unregistered_fd_info(info);
        real_close(fd);
        errno = saved;
        return -1;
    }
    set_fd_info(fd, info);
    return fd;
}

/* glibc _FORTIFY_SOURCE redirects open calls without O_CREAT to these names. */
int __open_2(const char *pathname, int flags) {
    return open(pathname, flags);
}

int __open64_2(const char *pathname, int flags) {
    return open64(pathname, flags);
}

int __openat_2(int dirfd, const char *pathname, int flags) {
    return openat(dirfd, pathname, flags);
}

int __openat64_2(int dirfd, const char *pathname, int flags) {
    return openat64(dirfd, pathname, flags);
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

/* mmap 按需解压：后台异步解压上下文 */
typedef struct {
    int fd;               /* dup 的文件描述符 */
    uint8_t *buf;         /* 匿名内存基址 */
    size_t preload_len;   /* 已同步预解压的字节数 */
    size_t total_len;     /* 总映射长度 */
    off64_t offset;       /* 映射起始逻辑偏移 */
    int final_prot;       /* 最终保护位（mmap 时请求的保护位） */
    volatile int done;    /* 后台线程完成标志 */
    pthread_t thread;
} mmap_bg_ctx_t;

typedef struct {
    void *addr;       /* 返回给应用的地址 */
    size_t len;       /* 映射长度 */
    void *buf;        /* 匿名内存基址（可能与 addr 相同） */
    size_t buf_len;   /* 匿名内存总长度 */
    int active;
    mmap_bg_ctx_t *bg; /* 后台解压上下文（NULL 表示已全部同步解压） */
} mmap_track_t;

static mmap_track_t g_mmap_table[MAX_MMAP_TRACK];
static pthread_mutex_t g_mmap_lock = PTHREAD_MUTEX_INITIALIZER;

#ifndef MMAP_PRELOAD_MB
#define MMAP_PRELOAD_MB 16
#endif
#define MMAP_PRELOAD_SIZE ((size_t)MMAP_PRELOAD_MB * 1024 * 1024)

/* 后台线程：异步解压 mmap 的剩余部分 */
static void *mmap_background_decompress(void *arg) {
    mmap_bg_ctx_t *ctx = (mmap_bg_ctx_t *)arg;

    fd_info_t *info = (fd_info_t *)calloc(1, sizeof(fd_info_t));
    if (info && read_header(ctx->fd, info) == 0 && info->is_compressed) {
        ssize_t nread = read_compressed_at(ctx->fd, info,
            ctx->buf + ctx->preload_len,
            ctx->total_len - ctx->preload_len,
            ctx->offset + (off64_t)ctx->preload_len);
        if (nread < 0 || (size_t)nread < ctx->total_len - ctx->preload_len) {
            fprintf(stderr, "[HOOK] mmap background decompress failed: nread=%zd, expected=%zu\n",
                    nread, ctx->total_len - ctx->preload_len);
        }
    }

    if (info) {
        free(info->blocks);
        free(info);
    }

    /* 解压完成后，将剩余部分调整为最终保护位 */
    if (ctx->final_prot != 0 &&
        (ctx->final_prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) != (PROT_READ | PROT_WRITE)) {
        size_t remaining = ctx->total_len - ctx->preload_len;
        if (remaining > 0) {
            if (mprotect(ctx->buf + ctx->preload_len, remaining, ctx->final_prot) != 0) {
                fprintf(stderr, "[HOOK] mmap background mprotect failed: %s\n", strerror(errno));
            }
        }
    }

    if (ctx->fd >= 0) {
        close(ctx->fd);
        ctx->fd = -1;
    }
    ctx->done = 1;
    return NULL;
}

static int add_mmap_track(void *addr, size_t len, void *buf, size_t buf_len, mmap_bg_ctx_t *bg) {
    pthread_mutex_lock(&g_mmap_lock);
    for (int i = 0; i < MAX_MMAP_TRACK; i++) {
        if (!g_mmap_table[i].active) {
            g_mmap_table[i].addr = addr;
            g_mmap_table[i].len = len;
            g_mmap_table[i].buf = buf;
            g_mmap_table[i].buf_len = buf_len;
            g_mmap_table[i].bg = bg;
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
    mmap_bg_ctx_t *bg_ctx = NULL;

    if (g_hooks_disabled || !real_mmap) {
        if (!real_mmap) { errno = ENOSYS; return MAP_FAILED; }
        return real_mmap(addr, length, prot, flags, fd, offset);
    }

    fd_info_t *info = get_fd_info(fd);
    if (!info || !info->has_header) {
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

    /*
     * 正确性优先：在返回映射前同步填充完整范围。
     *
     * 旧实现只同步填充前 16 MB，随后让后台线程写入其余匿名页。应用若在
     * 后台完成前访问后半段，会读到匿名页的初始零值，违反 mmap 的可见性
     * 语义。真正的按需解压需要 userfaultfd（或等价的缺页同步机制），不能
     * 用无同步的后台 memcpy 模拟。
     */
    ssize_t nread;
    if (info->is_compressed) {
        nread = read_compressed_at(fd, info, buf, length, (off64_t)offset);
    } else {
        nread = real_pread64(fd, buf, length,
                             (off64_t)info->hdr.header_size + (off64_t)offset);
    }
    if (nread < 0 || (size_t)nread < length) {
        real_munmap(buf, length);
        errno = EIO;
        return MAP_FAILED;
    }

    /* 按请求调整保护位 */
    if ((prot & (PROT_READ | PROT_WRITE | PROT_EXEC)) != (PROT_READ | PROT_WRITE)) {
        if (bg_ctx) {
            /* 大文件 + 后台线程：只保护预解压部分，剩余部分由后台线程完成后自行保护 */
            if (mprotect(buf, MMAP_PRELOAD_SIZE, prot) != 0) {
                if (!bg_ctx->done) pthread_join(bg_ctx->thread, NULL);
                if (bg_ctx->fd >= 0) close(bg_ctx->fd);
                free(bg_ctx);
                real_munmap(buf, length);
                errno = ENOMEM;
                return MAP_FAILED;
            }
        } else {
            if (mprotect(buf, length, prot) != 0) {
                real_munmap(buf, length);
                errno = ENOMEM;
                return MAP_FAILED;
            }
        }
    }

    /* 记录映射 */
    if (add_mmap_track(buf, length, buf, length, bg_ctx) != 0) {
        if (bg_ctx) {
            if (!bg_ctx->done) pthread_join(bg_ctx->thread, NULL);
            if (bg_ctx->fd >= 0) close(bg_ctx->fd);
            free(bg_ctx);
        }
        real_munmap(buf, length);
        errno = ENOMEM;
        return MAP_FAILED;
    }

    return buf;
}

int munmap(void *addr, size_t length) {
    (void)length;
    if (!real_munmap) { errno = ENOSYS; return -1; }

    pthread_mutex_lock(&g_mmap_lock);
    for (int i = 0; i < MAX_MMAP_TRACK; i++) {
        if (g_mmap_table[i].active && g_mmap_table[i].addr == addr) {
            mmap_track_t *track = &g_mmap_table[i];
            mmap_bg_ctx_t *bg = track->bg;
            track->bg = NULL;
            track->active = 0;
            pthread_mutex_unlock(&g_mmap_lock);

            if (bg) {
                if (!bg->done) {
                    pthread_join(bg->thread, NULL);
                }
                if (bg->fd >= 0) {
                    close(bg->fd);
                }
                free(bg);
            }
            return real_munmap(addr, length);
        }
    }
    pthread_mutex_unlock(&g_mmap_lock);
    return real_munmap(addr, length);
}

int msync(void *addr, size_t length, int flags) {
    (void)length; (void)flags;
    if (!real_msync) { errno = ENOSYS; return -1; }

    pthread_mutex_lock(&g_mmap_lock);
    for (int i = 0; i < MAX_MMAP_TRACK; i++) {
        if (g_mmap_table[i].active && g_mmap_table[i].addr == addr) {
            mmap_bg_ctx_t *bg = g_mmap_table[i].bg;
            pthread_mutex_unlock(&g_mmap_lock);

            if (bg && !bg->done) {
                /* 等待后台解压完成后再返回 */
                pthread_join(bg->thread, NULL);
            }
            /* 匿名 MAP_PRIVATE 映射不需要 sync */
            return 0;
        }
    }
    pthread_mutex_unlock(&g_mmap_lock);
    return real_msync(addr, length, flags);
}
