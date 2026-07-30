/*
 * gpu_lz4.cu - NVIDIA nvCOMP LZ4 backend for GPUC
 *
 * 为 GPUC 提供 LZ4 压缩/解压能力，作为 SGLZ 的替代算法。
 * 每个 128KB block 作为一个独立的 nvCOMP chunk 处理，输出格式：
 *   [1B flag][payload]
 *   flag = 0: payload 为原始未压缩数据
 *   flag = 1: payload 为 LZ4 压缩数据
 */

#include <cuda_runtime.h>
#include <nvcomp/lz4.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <time.h>
#include <sys/resource.h>
#include <sched.h>

#include "gpu_compress_api.h"

#define LZ4_BLOCK_SIZE (128 * 1024)

static int g_gpu_lz4_inited = 0;

/* 持久化设备内存池（单 block） */
static void *g_d_in = NULL;
static void *g_d_out = NULL;
static void *g_d_temp = NULL;
static void **g_d_in_ptrs = NULL;       /* 单元素设备指针数组 */
static void **g_d_out_ptrs = NULL;      /* 单元素设备指针数组 */
static size_t *g_d_in_len = NULL;       /* 单 chunk 原始长度（设备内存） */
static size_t *g_d_comp_len = NULL;     /* 单 chunk 压缩后长度（设备内存） */
static size_t *g_d_out_len = NULL;      /* 单 chunk 解压期望长度（设备内存） */
static size_t *g_d_actual_out = NULL;   /* 单 chunk 解压实际长度（设备内存） */
static nvcompStatus_t *g_d_status = NULL;
static size_t g_d_in_cap = 0;
static size_t g_d_out_cap = 0;
static size_t g_d_temp_cap = 0;
static size_t g_max_out_chunk = 0;
static pthread_mutex_t g_lz4_init_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t g_cuda_flags_once = PTHREAD_ONCE_INIT;

typedef struct lz4_request {
    int n;
    const uint8_t **in_bufs;
    const size_t *in_lens;
    uint8_t **out_bufs;
    const size_t *out_lens;
    int result;
    int done;
    struct timespec queued_at;
    gpu_lz4_profile_t profile;
    pthread_cond_t done_cv;
    struct lz4_request *next;
} lz4_request_t;

typedef struct lz4_decomp_pool {
    cudaStream_t stream;
    cudaEvent_t h2d_start;
    cudaEvent_t h2d_done;
    cudaEvent_t kernel_done;
    cudaEvent_t d2h_done;
    void **h_in_ptrs;
    void **h_out_ptrs;
    size_t *h_comp_lens;
    size_t *h_out_lens;
    size_t *h_actual;
    nvcompStatus_t *h_status;
    int *indices;
    void *d_in;
    void *d_out;
    void *d_temp;
    void **d_in_ptrs;
    void **d_out_ptrs;
    size_t *d_comp_lens;
    size_t *d_out_lens;
    size_t *d_actual;
    nvcompStatus_t *d_status;
    size_t in_cap;
    size_t out_cap;
    size_t temp_cap;
    size_t batch_cap;
    int initialized;
} lz4_decomp_pool_t;

static pthread_mutex_t g_worker_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_worker_cv = PTHREAD_COND_INITIALIZER;
static pthread_t g_worker_thread;
static int g_worker_started = 0;
static int g_worker_stop = 0;
static lz4_request_t *g_worker_head = NULL;
static lz4_request_t *g_worker_tail = NULL;
static __thread gpu_lz4_profile_t g_last_profile;

static double elapsed_ms(const struct timespec *a, const struct timespec *b) {
    return (double)(b->tv_sec - a->tv_sec) * 1000.0 +
           (double)(b->tv_nsec - a->tv_nsec) / 1000000.0;
}

static double timeval_ms(const struct timeval *tv) {
    return (double)tv->tv_sec * 1000.0 + (double)tv->tv_usec / 1000.0;
}

static size_t grow_capacity(size_t value) {
    size_t cap = 1;
    while (cap < value && cap <= SIZE_MAX / 2) cap <<= 1;
    return cap < value ? value : cap;
}

static void configure_cuda_wait_policy(void) {
    const char *spin = getenv("GPUC_CUDA_SPIN_WAIT");
    if (!spin || strcmp(spin, "1") != 0) {
        /* Blocking synchronization is essential for an offload service:
         * application/worker CPU must sleep while the GPU is executing. */
        cudaError_t err = cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
        if (err != cudaSuccess && err != cudaErrorSetOnActiveProcess)
            fprintf(stderr, "[gpu_lz4] cudaSetDeviceFlags failed: %s\n",
                    cudaGetErrorString(err));
        (void)cudaGetLastError();
    }
}

static int gpu_lz4_ensure_buffers(size_t in_len, size_t out_cap, size_t temp_bytes) {
    if (in_len > g_d_in_cap) {
        if (g_d_in) cudaFree(g_d_in);
        g_d_in = NULL;
        if (cudaMalloc(&g_d_in, in_len) != cudaSuccess) return -1;
        g_d_in_cap = in_len;
    }
    if (out_cap > g_d_out_cap) {
        if (g_d_out) cudaFree(g_d_out);
        g_d_out = NULL;
        if (cudaMalloc(&g_d_out, out_cap) != cudaSuccess) return -1;
        g_d_out_cap = out_cap;
    }
    /* nvCOMP 不接受 NULL temp 指针，即使 temp_bytes == 0 也至少申请 1 字节 */
    size_t temp_alloc = temp_bytes > 0 ? temp_bytes : 1;
    if (temp_alloc > g_d_temp_cap) {
        if (g_d_temp) cudaFree(g_d_temp);
        g_d_temp = NULL;
        if (cudaMalloc(&g_d_temp, temp_alloc) != cudaSuccess) return -1;
        g_d_temp_cap = temp_alloc;
    }
    if (!g_d_in_ptrs && cudaMalloc(&g_d_in_ptrs, sizeof(void *)) != cudaSuccess) return -1;
    if (!g_d_out_ptrs && cudaMalloc(&g_d_out_ptrs, sizeof(void *)) != cudaSuccess) return -1;
    if (!g_d_in_len && cudaMalloc(&g_d_in_len, sizeof(size_t)) != cudaSuccess) return -1;
    if (!g_d_comp_len && cudaMalloc(&g_d_comp_len, sizeof(size_t)) != cudaSuccess) return -1;
    if (!g_d_out_len && cudaMalloc(&g_d_out_len, sizeof(size_t)) != cudaSuccess) return -1;
    if (!g_d_actual_out && cudaMalloc(&g_d_actual_out, sizeof(size_t)) != cudaSuccess) return -1;
    if (!g_d_status && cudaMalloc(&g_d_status, sizeof(nvcompStatus_t)) != cudaSuccess) return -1;
    return 0;
}

static void decomp_pool_release(lz4_decomp_pool_t *p) {
    if (p->d_in) cudaFree(p->d_in);
    if (p->d_out) cudaFree(p->d_out);
    if (p->d_temp) cudaFree(p->d_temp);
    if (p->d_in_ptrs) cudaFree(p->d_in_ptrs);
    if (p->d_out_ptrs) cudaFree(p->d_out_ptrs);
    if (p->d_comp_lens) cudaFree(p->d_comp_lens);
    if (p->d_out_lens) cudaFree(p->d_out_lens);
    if (p->d_actual) cudaFree(p->d_actual);
    if (p->d_status) cudaFree(p->d_status);
    if (p->h_in_ptrs) cudaFreeHost(p->h_in_ptrs);
    if (p->h_out_ptrs) cudaFreeHost(p->h_out_ptrs);
    if (p->h_comp_lens) cudaFreeHost(p->h_comp_lens);
    if (p->h_out_lens) cudaFreeHost(p->h_out_lens);
    if (p->h_actual) cudaFreeHost(p->h_actual);
    if (p->h_status) cudaFreeHost(p->h_status);
    free(p->indices);
    if (p->h2d_start) cudaEventDestroy(p->h2d_start);
    if (p->h2d_done) cudaEventDestroy(p->h2d_done);
    if (p->kernel_done) cudaEventDestroy(p->kernel_done);
    if (p->d2h_done) cudaEventDestroy(p->d2h_done);
    if (p->stream) cudaStreamDestroy(p->stream);
    memset(p, 0, sizeof(*p));
}

static int decomp_pool_init(lz4_decomp_pool_t *p) {
    if (p->initialized) return 0;
    if (cudaStreamCreateWithFlags(&p->stream, cudaStreamNonBlocking) != cudaSuccess ||
        cudaEventCreate(&p->h2d_start) != cudaSuccess ||
        cudaEventCreate(&p->h2d_done) != cudaSuccess ||
        cudaEventCreate(&p->kernel_done) != cudaSuccess ||
        cudaEventCreate(&p->d2h_done) != cudaSuccess) {
        decomp_pool_release(p);
        return -1;
    }
    p->initialized = 1;
    return 0;
}

static int decomp_pool_reserve(lz4_decomp_pool_t *p, size_t n,
                               size_t in_bytes, size_t out_bytes,
                               size_t temp_bytes) {
    if (decomp_pool_init(p) != 0) return -1;
    size_t new_n = grow_capacity(n);
    size_t new_in = grow_capacity(in_bytes ? in_bytes : 1);
    size_t new_out = grow_capacity(out_bytes ? out_bytes : 1);
    size_t new_temp = grow_capacity(temp_bytes ? temp_bytes : 1);

    if (new_in > p->in_cap) {
        if (p->d_in) cudaFree(p->d_in);
        p->d_in = NULL;
        p->in_cap = 0;
        if (cudaMalloc(&p->d_in, new_in) != cudaSuccess)
            return -1;
        p->in_cap = new_in;
    }
    if (new_out > p->out_cap) {
        if (p->d_out) cudaFree(p->d_out);
        p->d_out = NULL;
        p->out_cap = 0;
        if (cudaMalloc(&p->d_out, new_out) != cudaSuccess)
            return -1;
        p->out_cap = new_out;
    }
    if (new_temp > p->temp_cap) {
        if (p->d_temp) cudaFree(p->d_temp);
        p->d_temp = NULL;
        p->temp_cap = 0;
        if (cudaMalloc(&p->d_temp, new_temp) != cudaSuccess) return -1;
        p->temp_cap = new_temp;
    }
    if (new_n > p->batch_cap) {
        if (p->h_in_ptrs) cudaFreeHost(p->h_in_ptrs);
        if (p->h_out_ptrs) cudaFreeHost(p->h_out_ptrs);
        if (p->h_comp_lens) cudaFreeHost(p->h_comp_lens);
        if (p->h_out_lens) cudaFreeHost(p->h_out_lens);
        if (p->h_actual) cudaFreeHost(p->h_actual);
        if (p->h_status) cudaFreeHost(p->h_status);
        if (p->d_in_ptrs) cudaFree(p->d_in_ptrs);
        if (p->d_out_ptrs) cudaFree(p->d_out_ptrs);
        if (p->d_comp_lens) cudaFree(p->d_comp_lens);
        if (p->d_out_lens) cudaFree(p->d_out_lens);
        if (p->d_actual) cudaFree(p->d_actual);
        if (p->d_status) cudaFree(p->d_status);
        free(p->indices);
        p->h_in_ptrs = p->h_out_ptrs = NULL;
        p->h_comp_lens = p->h_out_lens = p->h_actual = NULL;
        p->h_status = NULL;
        p->d_in_ptrs = p->d_out_ptrs = NULL;
        p->d_comp_lens = p->d_out_lens = p->d_actual = NULL;
        p->d_status = NULL;
        p->indices = NULL;
        p->batch_cap = 0;
        size_t ptr_bytes = new_n * sizeof(void *);
        size_t size_bytes = new_n * sizeof(size_t);
        size_t status_bytes = new_n * sizeof(nvcompStatus_t);
        if (cudaHostAlloc(&p->h_in_ptrs, ptr_bytes, cudaHostAllocDefault) != cudaSuccess ||
            cudaHostAlloc(&p->h_out_ptrs, ptr_bytes, cudaHostAllocDefault) != cudaSuccess ||
            cudaHostAlloc(&p->h_comp_lens, size_bytes, cudaHostAllocDefault) != cudaSuccess ||
            cudaHostAlloc(&p->h_out_lens, size_bytes, cudaHostAllocDefault) != cudaSuccess ||
            cudaHostAlloc(&p->h_actual, size_bytes, cudaHostAllocDefault) != cudaSuccess ||
            cudaHostAlloc(&p->h_status, status_bytes, cudaHostAllocDefault) != cudaSuccess ||
            cudaMalloc(&p->d_in_ptrs, ptr_bytes) != cudaSuccess ||
            cudaMalloc(&p->d_out_ptrs, ptr_bytes) != cudaSuccess ||
            cudaMalloc(&p->d_comp_lens, size_bytes) != cudaSuccess ||
            cudaMalloc(&p->d_out_lens, size_bytes) != cudaSuccess ||
            cudaMalloc(&p->d_actual, size_bytes) != cudaSuccess ||
            cudaMalloc(&p->d_status, status_bytes) != cudaSuccess)
            return -1;
        p->indices = (int *)malloc(new_n * sizeof(int));
        if (!p->indices) return -1;
        p->batch_cap = new_n;
    }
    return 0;
}

static int gpu_lz4_init_unlocked(void) {
    if (g_gpu_lz4_inited) return 0;
    pthread_once(&g_cuda_flags_once, configure_cuda_wait_policy);

    nvcompBatchedLZ4Opts_t opts = nvcompBatchedLZ4DefaultOpts;
    nvcompStatus_t s;

    s = nvcompBatchedLZ4CompressGetMaxOutputChunkSize(LZ4_BLOCK_SIZE, opts, &g_max_out_chunk);
    if (s != nvcompSuccess) {
        fprintf(stderr, "[gpu_lz4] nvcompBatchedLZ4CompressGetMaxOutputChunkSize failed\n");
        return -1;
    }

    size_t comp_temp = 0;
    s = nvcompBatchedLZ4CompressGetTempSize(1, LZ4_BLOCK_SIZE, opts, &comp_temp);
    if (s != nvcompSuccess) {
        fprintf(stderr, "[gpu_lz4] nvcompBatchedLZ4CompressGetTempSize failed\n");
        return -1;
    }

    size_t decomp_temp = 0;
    s = nvcompBatchedLZ4DecompressGetTempSize(1, LZ4_BLOCK_SIZE, &decomp_temp);
    if (s != nvcompSuccess) {
        fprintf(stderr, "[gpu_lz4] nvcompBatchedLZ4DecompressGetTempSize failed\n");
        return -1;
    }

    size_t temp_need = comp_temp > decomp_temp ? comp_temp : decomp_temp;
    if (gpu_lz4_ensure_buffers(LZ4_BLOCK_SIZE, g_max_out_chunk, temp_need) != 0) {
        fprintf(stderr, "[gpu_lz4] device buffer allocation failed\n");
        return -1;
    }

    g_gpu_lz4_inited = 1;
    return 0;
}

int gpu_lz4_init(void) {
    pthread_mutex_lock(&g_lz4_init_lock);
    int rc = gpu_lz4_init_unlocked();
    pthread_mutex_unlock(&g_lz4_init_lock);
    return rc;
}

static void gpu_lz4_release_single_pool(void) {
    if (g_d_in) { cudaFree(g_d_in); g_d_in = NULL; }
    if (g_d_out) { cudaFree(g_d_out); g_d_out = NULL; }
    if (g_d_temp) { cudaFree(g_d_temp); g_d_temp = NULL; }
    if (g_d_in_ptrs) { cudaFree(g_d_in_ptrs); g_d_in_ptrs = NULL; }
    if (g_d_out_ptrs) { cudaFree(g_d_out_ptrs); g_d_out_ptrs = NULL; }
    if (g_d_in_len) { cudaFree(g_d_in_len); g_d_in_len = NULL; }
    if (g_d_comp_len) { cudaFree(g_d_comp_len); g_d_comp_len = NULL; }
    if (g_d_out_len) { cudaFree(g_d_out_len); g_d_out_len = NULL; }
    if (g_d_actual_out) { cudaFree(g_d_actual_out); g_d_actual_out = NULL; }
    if (g_d_status) { cudaFree(g_d_status); g_d_status = NULL; }
    g_d_in_cap = 0;
    g_d_out_cap = 0;
    g_d_temp_cap = 0;
    g_gpu_lz4_inited = 0;
}

/* 压缩单个 128KB 块；返回 0 成功，-1 失败 */
static int gpu_lz4_compress_one(const uint8_t *in, size_t in_len,
                                uint8_t *out, size_t out_cap,
                                size_t *out_len) {
    if (gpu_lz4_init() != 0) return -1;

    nvcompBatchedLZ4Opts_t opts = nvcompBatchedLZ4DefaultOpts;
    nvcompStatus_t s;

    size_t max_out = 0;
    s = nvcompBatchedLZ4CompressGetMaxOutputChunkSize(in_len, opts, &max_out);
    if (s != nvcompSuccess) return -1;

    size_t temp_need = 0;
    s = nvcompBatchedLZ4CompressGetTempSize(1, in_len, opts, &temp_need);
    if (s != nvcompSuccess) return -1;

    if (1 + max_out > out_cap) {
        fprintf(stderr, "[gpu_lz4] output cap too small: need %zu, have %zu\n", 1 + max_out, out_cap);
        return -1;
    }
    if (gpu_lz4_ensure_buffers(in_len, max_out, temp_need) != 0) return -1;

    if (cudaMemcpy(g_d_in, in, in_len, cudaMemcpyHostToDevice) != cudaSuccess) return -1;
    if (cudaMemcpy(g_d_in_len, &in_len, sizeof(size_t), cudaMemcpyHostToDevice) != cudaSuccess) return -1;
    if (cudaMemcpy(g_d_in_ptrs, &g_d_in, sizeof(void *), cudaMemcpyHostToDevice) != cudaSuccess) return -1;
    if (cudaMemcpy(g_d_out_ptrs, &g_d_out, sizeof(void *), cudaMemcpyHostToDevice) != cudaSuccess) return -1;

    s = nvcompBatchedLZ4CompressAsync((const void *const *)g_d_in_ptrs, g_d_in_len, in_len, 1,
                                      g_d_temp, temp_need,
                                      g_d_out_ptrs, g_d_comp_len,
                                      opts, 0);
    if (s != nvcompSuccess) {
        fprintf(stderr, "[gpu_lz4] compress async launch failed (status=%d)\n", (int)s);
        return -1;
    }
    if (cudaStreamSynchronize(0) != cudaSuccess) return -1;

    size_t comp_len = 0;
    if (cudaMemcpy(&comp_len, g_d_comp_len, sizeof(size_t), cudaMemcpyDeviceToHost) != cudaSuccess) return -1;

    if (comp_len < in_len) {
        out[0] = 1; /* LZ4 compressed */
        if (cudaMemcpy(out + 1, g_d_out, comp_len, cudaMemcpyDeviceToHost) != cudaSuccess) return -1;
        *out_len = 1 + comp_len;
    } else {
        out[0] = 0; /* raw fallback */
        memcpy(out + 1, in, in_len);
        *out_len = 1 + in_len;
    }
    return 0;
}

/* 解压单个 128KB 块 */
static int gpu_lz4_decompress_one(const uint8_t *in, size_t in_len,
                                  uint8_t *out, size_t out_len) {
    if (in_len == 0 || out_len == 0) return -1;
    uint8_t flag = in[0];
    if (flag == 0) {
        if (in_len - 1 < out_len) return -1;
        memcpy(out, in + 1, out_len);
        return 0;
    }
    if (flag != 1) return -1;

    if (gpu_lz4_init() != 0) return -1;

    size_t comp_len = in_len - 1;
    size_t temp_need = 0;
    nvcompStatus_t s = nvcompBatchedLZ4DecompressGetTempSize(1, LZ4_BLOCK_SIZE, &temp_need);
    if (s != nvcompSuccess) return -1;

    if (gpu_lz4_ensure_buffers(comp_len, out_len, temp_need) != 0) return -1;
    if (cudaMemcpy(g_d_in, in + 1, comp_len, cudaMemcpyHostToDevice) != cudaSuccess) return -1;

    if (cudaMemcpy(g_d_comp_len, &comp_len, sizeof(size_t), cudaMemcpyHostToDevice) != cudaSuccess) return -1;
    if (cudaMemcpy(g_d_out_len, &out_len, sizeof(size_t), cudaMemcpyHostToDevice) != cudaSuccess) return -1;
    if (cudaMemcpy(g_d_in_ptrs, &g_d_in, sizeof(void *), cudaMemcpyHostToDevice) != cudaSuccess) return -1;
    if (cudaMemcpy(g_d_out_ptrs, &g_d_out, sizeof(void *), cudaMemcpyHostToDevice) != cudaSuccess) return -1;

    s = nvcompBatchedLZ4DecompressAsync((const void *const *)g_d_in_ptrs, g_d_comp_len, g_d_out_len,
                                        g_d_actual_out, 1,
                                        g_d_temp, temp_need,
                                        g_d_out_ptrs, g_d_status, 0);
    if (s != nvcompSuccess) {
        fprintf(stderr, "[gpu_lz4] decompress async launch failed (status=%d)\n", (int)s);
        return -1;
    }
    if (cudaStreamSynchronize(0) != cudaSuccess) return -1;

    size_t actual_out = 0;
    if (cudaMemcpy(&actual_out, g_d_actual_out, sizeof(size_t), cudaMemcpyDeviceToHost) != cudaSuccess) return -1;
    if (actual_out != out_len) {
        fprintf(stderr, "[gpu_lz4] decompress size mismatch: %zu vs %zu\n", actual_out, out_len);
        return -1;
    }
    if (cudaMemcpy(out, g_d_out, out_len, cudaMemcpyDeviceToHost) != cudaSuccess) return -1;
    return 0;
}

int gpu_lz4_compress_batch(int n,
                           const uint8_t **in_bufs, const size_t *in_lens,
                           uint8_t **out_bufs, const size_t *out_caps,
                           size_t *out_lens) {
    if (n <= 0) return 0;
    for (int i = 0; i < n; i++) {
        if (gpu_lz4_compress_one(in_bufs[i], in_lens[i], out_bufs[i], out_caps[i], &out_lens[i]) != 0)
            return -1;
    }
    return n;
}

static int process_lz4_request(lz4_decomp_pool_t *p, lz4_request_t *r) {
    struct timespec total_begin, pack_begin, pack_end, unpack_begin, total_end;
    clock_gettime(CLOCK_MONOTONIC, &total_begin);
    r->profile.queue_ms = elapsed_ms(&r->queued_at, &total_begin);

    int m = 0;
    size_t in_bytes = 0, out_bytes = 0, max_out = 0;
    for (int i = 0; i < r->n; i++) {
        if (!r->in_bufs[i] || r->in_lens[i] == 0 ||
            !r->out_bufs[i] || r->out_lens[i] == 0)
            return -1;
        if (r->in_bufs[i][0] == 0) {
            if (r->in_lens[i] - 1 < r->out_lens[i]) return -1;
            memcpy(r->out_bufs[i], r->in_bufs[i] + 1, r->out_lens[i]);
        } else if (r->in_bufs[i][0] == 1) {
            m++;
            in_bytes += r->in_lens[i] - 1;
            out_bytes += r->out_lens[i];
            if (r->out_lens[i] > max_out) max_out = r->out_lens[i];
        } else {
            return -1;
        }
    }
    r->profile.compressed_blocks = (size_t)m;
    r->profile.input_bytes = in_bytes;
    r->profile.output_bytes = out_bytes;
    if (m == 0) {
        clock_gettime(CLOCK_MONOTONIC, &total_end);
        r->profile.total_ms = elapsed_ms(&total_begin, &total_end);
        return r->n;
    }

    size_t temp_bytes = 0;
    if (nvcompBatchedLZ4DecompressGetTempSize((size_t)m, max_out, &temp_bytes)
            != nvcompSuccess ||
        decomp_pool_reserve(p, (size_t)m, in_bytes, out_bytes, temp_bytes) != 0)
        return -1;

    clock_gettime(CLOCK_MONOTONIC, &pack_begin);
    size_t in_off = 0, out_off = 0;
    for (int i = 0, j = 0; i < r->n; i++) {
        if (r->in_bufs[i][0] != 1) continue;
        size_t comp_len = r->in_lens[i] - 1;
        p->indices[j] = i;
        p->h_comp_lens[j] = comp_len;
        p->h_out_lens[j] = r->out_lens[i];
        p->h_in_ptrs[j] = (uint8_t *)p->d_in + in_off;
        p->h_out_ptrs[j] = (uint8_t *)p->d_out + out_off;
        in_off += comp_len;
        out_off += r->out_lens[i];
        j++;
    }
    clock_gettime(CLOCK_MONOTONIC, &pack_end);
    r->profile.pack_ms = elapsed_ms(&pack_begin, &pack_end);

    size_t ptr_bytes = (size_t)m * sizeof(void *);
    size_t size_bytes = (size_t)m * sizeof(size_t);
    if (cudaEventRecord(p->h2d_start, p->stream) != cudaSuccess)
        return -1;
    in_off = 0;
    for (int j = 0; j < m; j++) {
        int i = p->indices[j];
        if (cudaMemcpyAsync((uint8_t *)p->d_in + in_off,
                            r->in_bufs[i] + 1, r->in_lens[i] - 1,
                            cudaMemcpyHostToDevice, p->stream) != cudaSuccess)
            return -1;
        in_off += r->in_lens[i] - 1;
    }
    if (cudaMemcpyAsync(p->d_in_ptrs, p->h_in_ptrs, ptr_bytes,
                        cudaMemcpyHostToDevice, p->stream) != cudaSuccess ||
        cudaMemcpyAsync(p->d_out_ptrs, p->h_out_ptrs, ptr_bytes,
                        cudaMemcpyHostToDevice, p->stream) != cudaSuccess ||
        cudaMemcpyAsync(p->d_comp_lens, p->h_comp_lens, size_bytes,
                        cudaMemcpyHostToDevice, p->stream) != cudaSuccess ||
        cudaMemcpyAsync(p->d_out_lens, p->h_out_lens, size_bytes,
                        cudaMemcpyHostToDevice, p->stream) != cudaSuccess ||
        cudaEventRecord(p->h2d_done, p->stream) != cudaSuccess)
        return -1;

    if (nvcompBatchedLZ4DecompressAsync(
            (const void *const *)p->d_in_ptrs, p->d_comp_lens, p->d_out_lens,
            p->d_actual, (size_t)m, p->d_temp, temp_bytes,
            p->d_out_ptrs, p->d_status, p->stream) != nvcompSuccess ||
        cudaEventRecord(p->kernel_done, p->stream) != cudaSuccess)
        return -1;

    if (cudaMemcpyAsync(p->h_actual, p->d_actual, size_bytes,
                        cudaMemcpyDeviceToHost, p->stream) != cudaSuccess ||
        cudaMemcpyAsync(p->h_status, p->d_status,
                        (size_t)m * sizeof(nvcompStatus_t),
                        cudaMemcpyDeviceToHost, p->stream) != cudaSuccess)
        return -1;
    /*
     * nvCOMP packs device outputs contiguously. Storage reads normally request
     * adjacent 128 KiB blocks, so merge adjacent host destinations into a
     * single D2H transfer instead of submitting one CUDA copy per block.
     * Wrapped/random batches still fall back to one copy per contiguous run.
     */
    out_off = 0;
    const char *disable_coalesce = getenv("GPUC_D2H_COALESCE");
    if (disable_coalesce && strcmp(disable_coalesce, "0") == 0) {
        for (int j = 0; j < m; j++) {
            int i = p->indices[j];
            if (cudaMemcpyAsync(r->out_bufs[i],
                                (uint8_t *)p->d_out + out_off,
                                r->out_lens[i], cudaMemcpyDeviceToHost,
                                p->stream) != cudaSuccess)
                return -1;
            out_off += r->out_lens[i];
        }
    } else {
        for (int first = 0; first < m;) {
            int first_i = p->indices[first];
            size_t run_bytes = r->out_lens[first_i];
            int next = first + 1;
            while (next < m) {
                int prev_i = p->indices[next - 1];
                int next_i = p->indices[next];
                if (r->out_bufs[next_i] !=
                    r->out_bufs[prev_i] + r->out_lens[prev_i])
                    break;
                run_bytes += r->out_lens[next_i];
                next++;
            }
            if (cudaMemcpyAsync(r->out_bufs[first_i],
                                (uint8_t *)p->d_out + out_off, run_bytes,
                                cudaMemcpyDeviceToHost,
                                p->stream) != cudaSuccess)
                return -1;
            out_off += run_bytes;
            first = next;
        }
    }
    if (cudaEventRecord(p->d2h_done, p->stream) != cudaSuccess ||
        cudaStreamSynchronize(p->stream) != cudaSuccess)
        return -1;

    float h2d_ms = 0.0f, kernel_ms = 0.0f, d2h_ms = 0.0f;
    (void)cudaEventElapsedTime(&h2d_ms, p->h2d_start, p->h2d_done);
    (void)cudaEventElapsedTime(&kernel_ms, p->h2d_done, p->kernel_done);
    (void)cudaEventElapsedTime(&d2h_ms, p->kernel_done, p->d2h_done);
    r->profile.h2d_ms = h2d_ms;
    r->profile.kernel_ms = kernel_ms;
    r->profile.d2h_ms = d2h_ms;

    clock_gettime(CLOCK_MONOTONIC, &unpack_begin);
    out_off = 0;
    for (int j = 0; j < m; j++) {
        int i = p->indices[j];
        if (p->h_status[j] != nvcompSuccess ||
            p->h_actual[j] != r->out_lens[i])
            return -1;
        out_off += r->out_lens[i];
    }
    clock_gettime(CLOCK_MONOTONIC, &total_end);
    r->profile.unpack_ms = elapsed_ms(&unpack_begin, &total_end);
    r->profile.total_ms = elapsed_ms(&total_begin, &total_end);
    return r->n;
}

static void *gpu_lz4_worker_main(void *unused) {
    (void)unused;
    const char *worker_cpu_env = getenv("GPUC_WORKER_CPU");
    if (worker_cpu_env && *worker_cpu_env) {
        int cpu = atoi(worker_cpu_env);
        if (cpu >= 0 && cpu < CPU_SETSIZE) {
            cpu_set_t set;
            CPU_ZERO(&set);
            CPU_SET(cpu, &set);
            (void)pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
        }
    }
    lz4_decomp_pool_t pool;
    memset(&pool, 0, sizeof(pool));
    for (;;) {
        pthread_mutex_lock(&g_worker_lock);
        while (!g_worker_head && !g_worker_stop)
            pthread_cond_wait(&g_worker_cv, &g_worker_lock);
        if (!g_worker_head && g_worker_stop) {
            pthread_mutex_unlock(&g_worker_lock);
            break;
        }
        lz4_request_t *r = g_worker_head;
        g_worker_head = r->next;
        if (!g_worker_head) g_worker_tail = NULL;
        pthread_mutex_unlock(&g_worker_lock);

        struct rusage cpu_before, cpu_after;
        memset(&cpu_before, 0, sizeof(cpu_before));
        memset(&cpu_after, 0, sizeof(cpu_after));
        (void)getrusage(RUSAGE_THREAD, &cpu_before);
        int result = process_lz4_request(&pool, r);
        (void)getrusage(RUSAGE_THREAD, &cpu_after);
        r->profile.worker_user_ms =
            timeval_ms(&cpu_after.ru_utime) - timeval_ms(&cpu_before.ru_utime);
        r->profile.worker_sys_ms =
            timeval_ms(&cpu_after.ru_stime) - timeval_ms(&cpu_before.ru_stime);
        pthread_mutex_lock(&g_worker_lock);
        r->result = result;
        r->done = 1;
        pthread_cond_signal(&r->done_cv);
        pthread_mutex_unlock(&g_worker_lock);
    }
    decomp_pool_release(&pool);
    return NULL;
}

static int ensure_worker_started(void) {
    pthread_mutex_lock(&g_worker_lock);
    if (!g_worker_started) {
        g_worker_stop = 0;
        if (pthread_create(&g_worker_thread, NULL, gpu_lz4_worker_main, NULL) != 0) {
            pthread_mutex_unlock(&g_worker_lock);
            return -1;
        }
        g_worker_started = 1;
    }
    pthread_mutex_unlock(&g_worker_lock);
    return 0;
}

int gpu_lz4_decompress_batch(int n,
                             const uint8_t **in_bufs, const size_t *in_lens,
                             uint8_t **out_bufs, const size_t *out_lens) {
    if (n <= 0) return 0;
    if (gpu_lz4_init() != 0 || ensure_worker_started() != 0) return -1;

    lz4_request_t request;
    memset(&request, 0, sizeof(request));
    request.n = n;
    request.in_bufs = in_bufs;
    request.in_lens = in_lens;
    request.out_bufs = out_bufs;
    request.out_lens = out_lens;
    clock_gettime(CLOCK_MONOTONIC, &request.queued_at);
    if (pthread_cond_init(&request.done_cv, NULL) != 0) return -1;

    pthread_mutex_lock(&g_worker_lock);
    if (g_worker_tail) g_worker_tail->next = &request;
    else g_worker_head = &request;
    g_worker_tail = &request;
    pthread_cond_signal(&g_worker_cv);
    while (!request.done)
        pthread_cond_wait(&request.done_cv, &g_worker_lock);
    pthread_mutex_unlock(&g_worker_lock);
    pthread_cond_destroy(&request.done_cv);
    g_last_profile = request.profile;
    if (request.result < 0)
        fprintf(stderr, "[gpu_lz4] worker batch decompress failed\n");
    return request.result;
}

int gpu_lz4_get_last_profile(gpu_lz4_profile_t *profile) {
    if (!profile) return -1;
    *profile = g_last_profile;
    return 0;
}

int gpu_lz4_host_alloc(void **ptr, size_t size) {
    if (!ptr || size == 0) return -1;
    *ptr = NULL;
    pthread_once(&g_cuda_flags_once, configure_cuda_wait_policy);
    return cudaHostAlloc(ptr, size, cudaHostAllocDefault) == cudaSuccess ? 0 : -1;
}

void gpu_lz4_host_free(void *ptr) {
    if (ptr) (void)cudaFreeHost(ptr);
}

void gpu_lz4_fini(void) {
    pthread_mutex_lock(&g_worker_lock);
    int join_worker = g_worker_started;
    if (join_worker) {
        g_worker_stop = 1;
        pthread_cond_broadcast(&g_worker_cv);
    }
    pthread_mutex_unlock(&g_worker_lock);
    if (join_worker) pthread_join(g_worker_thread, NULL);
    pthread_mutex_lock(&g_worker_lock);
    g_worker_started = 0;
    g_worker_stop = 0;
    g_worker_head = g_worker_tail = NULL;
    pthread_mutex_unlock(&g_worker_lock);

    pthread_mutex_lock(&g_lz4_init_lock);
    gpu_lz4_release_single_pool();
    pthread_mutex_unlock(&g_lz4_init_lock);
}

/* 单个 block 的兼容接口 */
int gpu_lz4_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap) {
    size_t in_len = LZ4_BLOCK_SIZE;
    size_t out_len = 0;
    if (gpu_lz4_compress_one(in, in_len, out, out_cap, &out_len) != 0) return -1;
    return (int)out_len;
}

int gpu_lz4_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len) {
    if (gpu_lz4_decompress_one(in, in_len, out, out_len) != 0) return -1;
    return 0;
}
