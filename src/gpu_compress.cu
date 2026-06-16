/*
 * gpu_compress.cu - Simple GPU LZ (SGLZ) 压缩/解压 CUDA 实现
 *
 * 设计要点：
 *   - 128KB block = 32 x 4KB chunks
 *   - 每个 CUDA thread 处理一个 4KB chunk，充分发挥 GPU 并行度
 *   - hash 表放置在 shared memory（stride layout 避免 bank conflict）
 *   - 压缩/解压均为 chunk 级别独立处理，无跨 chunk 依赖
 *   - 输出采用固定 slot 布局，简化地址计算
 *   - 支持批量处理（batch），摊销 CUDA 内存分配和拷贝开销
 */

#include "gpu_compress.cuh"
#include "gpu_compress_api.h"
#include <cuda_runtime.h>
#include <stdio.h>
#include <string.h>

/* 每个 chunk 在输出 buffer 中占用的固定 slot 大小 */
#define SGLZ_SLOT_SIZE (SGLZ_CHUNK_SIZE + 256)

/* ============================================================
 *  Device-side compression (single thread)
 * ============================================================ */

__device__ inline uint32_t sglz_hash3(const uint8_t *p) {
    return ((uint32_t)p[0] * 31 + (uint32_t)p[1] * 17 + (uint32_t)p[2]) & (SGLZ_HASH_SIZE - 1);
}

/* 压缩 kernel 的 threads-per-block（受 shared memory 容量限制） */
#define SGLZ_COMPRESS_TPB 64

__device__ int sglz_compress_chunk_device(const uint8_t *src, uint8_t *dst,
                                          int src_len, int *hash_tbl, int hash_stride) {
    for (int h = 0; h < SGLZ_HASH_SIZE; h++) hash_tbl[h * hash_stride] = -1;

    uint8_t *out = dst + 2;
    int out_pos = 0;
    int i = 0;

    while (i < src_len) {
        int best_len = 0;
        int best_off = 0;

        if (i + SGLZ_MIN_MATCH <= src_len) {
            uint32_t h = sglz_hash3(&src[i]);
            int prev = hash_tbl[h * hash_stride];
            if (prev >= 0 && (i - prev) <= SGLZ_MAX_OFFSET) {
                int max_len = src_len - i;
                if (max_len > SGLZ_MAX_MATCH) max_len = SGLZ_MAX_MATCH;
                int len = 0;
                while (len < max_len && src[prev + len] == src[i + len])
                    len++;
                if (len >= SGLZ_MIN_MATCH) {
                    best_len = len;
                    best_off = i - prev;
                }
            }
            hash_tbl[h * hash_stride] = i;
        }

        if (best_len > 0) {
            if (out_pos + 5 > SGLZ_SLOT_SIZE - 2) break;
            out[out_pos++] = 0x01;
            out[out_pos++] = best_off & 0xFF;
            out[out_pos++] = (best_off >> 8) & 0xFF;
            out[out_pos++] = best_len & 0xFF;
            out[out_pos++] = (best_len >> 8) & 0xFF;
            i += best_len;
        } else {
            int lit_start = i;
            i++;
            while (i < src_len) {
                if (i + SGLZ_MIN_MATCH <= src_len) {
                    uint32_t h = sglz_hash3(&src[i]);
                    int prev = hash_tbl[h * hash_stride];
                    if (prev >= 0 && (i - prev) <= SGLZ_MAX_OFFSET && src[prev] == src[i])
                        break;
                    hash_tbl[h * hash_stride] = i;
                }
                i++;
            }
            int lit_len = i - lit_start;
            if (out_pos + 3 + lit_len > SGLZ_SLOT_SIZE - 2) {
                i = lit_start;
                break;
            }
            out[out_pos++] = 0x00;
            out[out_pos++] = lit_len & 0xFF;
            out[out_pos++] = (lit_len >> 8) & 0xFF;
            for (int k = 0; k < lit_len; k++)
                out[out_pos++] = src[lit_start + k];
        }
    }

    if (i < src_len || (out_pos + 2) >= src_len) {
        uint16_t *cl = (uint16_t *)dst;
        *cl = 0xFFFF;
        for (int k = 0; k < src_len; k++)
            dst[2 + k] = src[k];
        return 2 + src_len;
    }

    uint16_t *cl = (uint16_t *)dst;
    *cl = (uint16_t)(out_pos + 2);
    return out_pos + 2;
}

/* ============================================================
 *  Device-side decompression (single thread)
 * ============================================================ */

__device__ int sglz_decompress_chunk_device(const uint8_t *src, uint8_t *dst, int dst_len) {
    uint16_t comp_len = (uint16_t)src[0] | ((uint16_t)src[1] << 8);
    if (comp_len == 0xFFFF) {
        for (int i = 0; i < dst_len && i < SGLZ_CHUNK_SIZE; i++)
            dst[i] = src[2 + i];
        return 2 + dst_len;
    }

    int in_pos = 2;
    int out_pos = 0;
    while (in_pos < comp_len && out_pos < dst_len) {
        uint8_t tag = src[in_pos++];
        if (tag == 0x00) {
            int len = (uint16_t)src[in_pos] | ((uint16_t)src[in_pos + 1] << 8);
            in_pos += 2;
            for (int k = 0; k < len && out_pos < dst_len; k++)
                dst[out_pos++] = src[in_pos++];
        } else if (tag == 0x01) {
            int off = (uint16_t)src[in_pos] | ((uint16_t)src[in_pos + 1] << 8);
            in_pos += 2;
            int len = (uint16_t)src[in_pos] | ((uint16_t)src[in_pos + 1] << 8);
            in_pos += 2;
            for (int k = 0; k < len && out_pos < dst_len; k++) {
                dst[out_pos] = dst[out_pos - off];
                out_pos++;
            }
        } else {
            break;
        }
    }
    return comp_len;
}

/* ============================================================
 *  CUDA Kernels
 * ============================================================ */

__global__ void sglz_compress_chunks_kernel(const uint8_t *in_buf,
                                            uint8_t *out_buf,
                                            const size_t *in_lens,
                                            size_t *out_lens,
                                            int total_chunks) {
    extern __shared__ int shared_hash[];

    int chunk_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (chunk_id >= total_chunks) return;

    int block_id = chunk_id / SGLZ_NCHUNKS;
    int warp_id  = chunk_id % SGLZ_NCHUNKS;

    size_t in_len = in_lens[block_id];
    int chunk_off = warp_id * SGLZ_CHUNK_SIZE;
    int chunk_len = (chunk_off + SGLZ_CHUNK_SIZE <= (int)in_len)
                        ? SGLZ_CHUNK_SIZE
                        : (int)in_len - chunk_off;

    const uint8_t *src = in_buf + block_id * SGLZ_BLOCK_SIZE + chunk_off;
    uint8_t *dst = out_buf + chunk_id * SGLZ_SLOT_SIZE;

    if (chunk_len <= 0) {
        *(uint16_t *)dst = 2;
        return;
    }

    int hash_stride = blockDim.x;
    int *hash_tbl = &shared_hash[threadIdx.x];
    int comp_size = sglz_compress_chunk_device(src, dst, chunk_len, hash_tbl, hash_stride);
    atomicAdd((unsigned long long *)(out_lens + block_id), (unsigned long long)comp_size);
}

__global__ void sglz_decompress_chunks_kernel(const uint8_t *in_buf,
                                              uint8_t *out_buf,
                                              const size_t *out_lens,
                                              int total_chunks) {
    int chunk_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (chunk_id >= total_chunks) return;

    int block_id = chunk_id / SGLZ_NCHUNKS;
    int warp_id  = chunk_id % SGLZ_NCHUNKS;

    size_t out_len = out_lens[block_id];
    int chunk_off = warp_id * SGLZ_CHUNK_SIZE;
    int chunk_out_len = (chunk_off + SGLZ_CHUNK_SIZE <= (int)out_len)
                            ? SGLZ_CHUNK_SIZE
                            : (int)out_len - chunk_off;

    if (chunk_out_len <= 0) return;

    const uint8_t *src = in_buf + chunk_id * SGLZ_SLOT_SIZE;
    uint8_t *dst = out_buf + block_id * SGLZ_BLOCK_SIZE + chunk_off;

    sglz_decompress_chunk_device(src, dst, chunk_out_len);
}

/* ============================================================
 *  Compact-format decompress kernel (zero slot conversion)
 * ============================================================ */

__global__ void sglz_decompress_compact_kernel(const uint8_t *compact_in,
                                                uint8_t *out_buf,
                                                const int *chunk_offsets,
                                                const size_t *out_lens,
                                                int total_chunks) {
    int chunk_id = blockIdx.x * blockDim.x + threadIdx.x;
    if (chunk_id >= total_chunks) return;

    int block_id = chunk_id / SGLZ_NCHUNKS;
    int warp_id  = chunk_id % SGLZ_NCHUNKS;

    size_t out_len = out_lens[block_id];
    int chunk_off = warp_id * SGLZ_CHUNK_SIZE;
    int chunk_out_len = (chunk_off + SGLZ_CHUNK_SIZE <= (int)out_len)
                            ? SGLZ_CHUNK_SIZE
                            : (int)out_len - chunk_off;

    if (chunk_out_len <= 0) return;

    const uint8_t *src = compact_in + chunk_offsets[chunk_id];
    uint8_t *dst = out_buf + block_id * SGLZ_BLOCK_SIZE + chunk_off;

    sglz_decompress_chunk_device(src, dst, chunk_out_len);
}

/* ============================================================
 *  Host-side wrappers
 * ============================================================ */

#define SGLZ_MAX_BATCH_BLOCKS 32
#define SGLZ_NUM_STREAMS 16

static int g_initialized = 0;
static cudaStream_t g_streams[SGLZ_NUM_STREAMS];

/* 预分配的 device 内存池（多 stream，用于 batch decompress 流水线） */
static void *g_d_batch_in[SGLZ_NUM_STREAMS] = {nullptr};
static void *g_d_batch_out[SGLZ_NUM_STREAMS] = {nullptr};
static void *g_d_batch_out_lens[SGLZ_NUM_STREAMS] = {nullptr};
static void *g_d_chunk_offsets[SGLZ_NUM_STREAMS] = {nullptr};

/* 预分配的 compress device 内存池（stream 0，用于 batch compress） */
static void *g_d_compress_in = nullptr;
static void *g_d_compress_out = nullptr;
static void *g_d_compress_in_lens = nullptr;
static void *g_d_compress_out_lens = nullptr;

int sglz_init(void) {
    if (g_initialized) return 0;
    cudaError_t err = cudaSetDevice(0);
    if (err != cudaSuccess) {
        fprintf(stderr, "[sglz] cudaSetDevice failed: %s\n", cudaGetErrorString(err));
        return -1;
    }
    /* 扩展 compress kernel 的 shared memory 上限到 64KB */
    err = cudaFuncSetAttribute(sglz_compress_chunks_kernel,
                               cudaFuncAttributeMaxDynamicSharedMemorySize,
                               SGLZ_COMPRESS_TPB * SGLZ_HASH_SIZE * sizeof(int));
    if (err != cudaSuccess) {
        fprintf(stderr, "[sglz] cudaFuncSetAttribute failed: %s\n", cudaGetErrorString(err));
        /* 非致命错误，继续运行 */
    }
    /* 创建多 CUDA stream 用于异步流水线并发（使用最高优先级，减少被其他 CUDA 任务抢占） */
    int leastPriority = 0, greatestPriority = 0;
    cudaDeviceGetStreamPriorityRange(&leastPriority, &greatestPriority);
    for (int s = 0; s < SGLZ_NUM_STREAMS; s++) {
        g_streams[s] = 0;
        err = cudaStreamCreateWithPriority(&g_streams[s], cudaStreamDefault, greatestPriority);
        if (err != cudaSuccess) {
            fprintf(stderr, "[sglz] cudaStreamCreateWithPriority(%d) failed: %s\n", s, cudaGetErrorString(err));
            /* fallback 到普通优先级 */
            err = cudaStreamCreate(&g_streams[s]);
            if (err != cudaSuccess) {
                fprintf(stderr, "[sglz] cudaStreamCreate(%d) failed: %s\n", s, cudaGetErrorString(err));
                g_streams[s] = 0;
            }
        }
    }
    /* 预分配 batch decompress 的 device 内存池（每个 stream 独立） */
    size_t batch_in_size = (size_t)SGLZ_MAX_BATCH_BLOCKS * SGLZ_NCHUNKS * SGLZ_SLOT_SIZE;
    size_t batch_out_size = (size_t)SGLZ_MAX_BATCH_BLOCKS * SGLZ_BLOCK_SIZE;
    for (int s = 0; s < SGLZ_NUM_STREAMS; s++) {
        g_d_batch_in[s] = nullptr;
        g_d_batch_out[s] = nullptr;
        g_d_batch_out_lens[s] = nullptr;
        g_d_chunk_offsets[s] = nullptr;
        err = cudaMalloc(&g_d_batch_in[s], batch_in_size);
        if (err != cudaSuccess) {
            fprintf(stderr, "[sglz] cudaMalloc(batch_in, stream=%d) failed: %s\n", s, cudaGetErrorString(err));
            sglz_fini();
            return -1;
        }
        err = cudaMalloc(&g_d_batch_out[s], batch_out_size);
        if (err != cudaSuccess) {
            fprintf(stderr, "[sglz] cudaMalloc(batch_out, stream=%d) failed: %s\n", s, cudaGetErrorString(err));
            sglz_fini();
            return -1;
        }
        err = cudaMalloc(&g_d_batch_out_lens[s], SGLZ_MAX_BATCH_BLOCKS * sizeof(size_t));
        if (err != cudaSuccess) {
            fprintf(stderr, "[sglz] cudaMalloc(batch_out_lens, stream=%d) failed: %s\n", s, cudaGetErrorString(err));
            sglz_fini();
            return -1;
        }
        err = cudaMalloc(&g_d_chunk_offsets[s], SGLZ_MAX_BATCH_BLOCKS * SGLZ_NCHUNKS * sizeof(int));
        if (err != cudaSuccess) {
            fprintf(stderr, "[sglz] cudaMalloc(chunk_offsets, stream=%d) failed: %s\n", s, cudaGetErrorString(err));
            sglz_fini();
            return -1;
        }
    }
    /* 预分配 batch compress 的 device 内存池（stream 0） */
    size_t compress_in_size = (size_t)SGLZ_MAX_BATCH_BLOCKS * SGLZ_BLOCK_SIZE;
    size_t compress_out_size = (size_t)SGLZ_MAX_BATCH_BLOCKS * SGLZ_NCHUNKS * SGLZ_SLOT_SIZE;
    err = cudaMalloc(&g_d_compress_in, compress_in_size);
    if (err != cudaSuccess) {
        fprintf(stderr, "[sglz] cudaMalloc(compress_in) failed: %s\n", cudaGetErrorString(err));
        sglz_fini();
        return -1;
    }
    err = cudaMalloc(&g_d_compress_out, compress_out_size);
    if (err != cudaSuccess) {
        fprintf(stderr, "[sglz] cudaMalloc(compress_out) failed: %s\n", cudaGetErrorString(err));
        sglz_fini();
        return -1;
    }
    err = cudaMalloc(&g_d_compress_in_lens, SGLZ_MAX_BATCH_BLOCKS * sizeof(size_t));
    if (err != cudaSuccess) {
        fprintf(stderr, "[sglz] cudaMalloc(compress_in_lens) failed: %s\n", cudaGetErrorString(err));
        sglz_fini();
        return -1;
    }
    err = cudaMalloc(&g_d_compress_out_lens, SGLZ_MAX_BATCH_BLOCKS * sizeof(size_t));
    if (err != cudaSuccess) {
        fprintf(stderr, "[sglz] cudaMalloc(compress_out_lens) failed: %s\n", cudaGetErrorString(err));
        sglz_fini();
        return -1;
    }
    g_initialized = 1;
    return 0;
}

void sglz_fini(void) {
    for (int s = 0; s < SGLZ_NUM_STREAMS; s++) {
        if (g_d_batch_in[s]) { cudaFree(g_d_batch_in[s]); g_d_batch_in[s] = nullptr; }
        if (g_d_batch_out[s]) { cudaFree(g_d_batch_out[s]); g_d_batch_out[s] = nullptr; }
        if (g_d_batch_out_lens[s]) { cudaFree(g_d_batch_out_lens[s]); g_d_batch_out_lens[s] = nullptr; }
        if (g_d_chunk_offsets[s]) { cudaFree(g_d_chunk_offsets[s]); g_d_chunk_offsets[s] = nullptr; }
        if (g_streams[s]) {
            cudaStreamDestroy(g_streams[s]);
            g_streams[s] = 0;
        }
    }
    if (g_d_compress_in) { cudaFree(g_d_compress_in); g_d_compress_in = nullptr; }
    if (g_d_compress_out) { cudaFree(g_d_compress_out); g_d_compress_out = nullptr; }
    if (g_d_compress_in_lens) { cudaFree(g_d_compress_in_lens); g_d_compress_in_lens = nullptr; }
    if (g_d_compress_out_lens) { cudaFree(g_d_compress_out_lens); g_d_compress_out_lens = nullptr; }
    g_initialized = 0;
}

/*
 * 单次 block 压缩（内部使用，保持接口兼容）
 */
static int do_compress_block(const uint8_t *h_in, uint8_t *h_out,
                             size_t in_len, size_t *out_len) {
    uint8_t *d_in = nullptr;
    uint8_t *d_out = nullptr;
    size_t *d_in_len = nullptr;
    size_t *d_out_len = nullptr;

    cudaMalloc(&d_in, SGLZ_BLOCK_SIZE);
    cudaMalloc(&d_out, SGLZ_NCHUNKS * SGLZ_SLOT_SIZE);
    cudaMalloc(&d_in_len, sizeof(size_t));
    cudaMalloc(&d_out_len, sizeof(size_t));

    cudaMemcpyAsync(d_in, h_in, in_len, cudaMemcpyHostToDevice, g_streams[0]);
    cudaMemcpyAsync(d_in_len, &in_len, sizeof(size_t), cudaMemcpyHostToDevice, g_streams[0]);
    cudaMemsetAsync(d_out_len, 0, sizeof(size_t), g_streams[0]);

    size_t shared_mem = SGLZ_NCHUNKS * SGLZ_HASH_SIZE * sizeof(int);
    sglz_compress_chunks_kernel<<<1, SGLZ_NCHUNKS, shared_mem, g_streams[0]>>>(d_in, d_out, d_in_len, d_out_len, SGLZ_NCHUNKS);
    cudaStreamSynchronize(g_streams[0]);

    size_t h_out_len = 0;
    cudaMemcpy(&h_out_len, d_out_len, sizeof(size_t), cudaMemcpyDeviceToHost);

    if (h_out_len > 0) {
        cudaMemcpy(h_out, d_out, SGLZ_NCHUNKS * SGLZ_SLOT_SIZE, cudaMemcpyDeviceToHost);
    }

    cudaFree(d_in);
    cudaFree(d_out);
    cudaFree(d_in_len);
    cudaFree(d_out_len);

    *out_len = h_out_len;
    return 0;
}

static int do_decompress_block(const uint8_t *h_in, uint8_t *h_out,
                               size_t out_len) {
    uint8_t *d_in = nullptr;
    uint8_t *d_out = nullptr;
    size_t *d_out_len = nullptr;

    cudaMalloc(&d_in, SGLZ_NCHUNKS * SGLZ_SLOT_SIZE);
    cudaMalloc(&d_out, SGLZ_BLOCK_SIZE);
    cudaMalloc(&d_out_len, sizeof(size_t));

    cudaMemcpyAsync(d_in, h_in, SGLZ_NCHUNKS * SGLZ_SLOT_SIZE, cudaMemcpyHostToDevice, g_streams[0]);
    cudaMemcpyAsync(d_out_len, &out_len, sizeof(size_t), cudaMemcpyHostToDevice, g_streams[0]);

    sglz_decompress_chunks_kernel<<<1, SGLZ_NCHUNKS, 0, g_streams[0]>>>(d_in, d_out, d_out_len, SGLZ_NCHUNKS);
    cudaStreamSynchronize(g_streams[0]);

    cudaMemcpy(h_out, d_out, out_len, cudaMemcpyDeviceToHost);

    cudaFree(d_in);
    cudaFree(d_out);
    cudaFree(d_out_len);
    return 0;
}

int sglz_compress_block(const uint8_t *in_buf, uint8_t *out_buf, size_t out_cap) {
    (void)out_cap;
    if (!g_initialized) sglz_init();

    size_t out_len = 0;
    do_compress_block(in_buf, out_buf, SGLZ_BLOCK_SIZE, &out_len);

    if (out_len == 0 || out_len >= SGLZ_BLOCK_SIZE) {
        return 0;
    }
    return (int)out_len;
}

int sglz_decompress_block(const uint8_t *in_buf, size_t in_len,
                          uint8_t *out_buf, size_t out_len) {
    if (!g_initialized) sglz_init();
    (void)in_len;
    do_decompress_block(in_buf, out_buf, out_len);
    return 0;
}

/*
 * 批量压缩（优化版：复用预分配 device 内存池，避免 cudaMalloc/cudaFree 开销）
 */
int sglz_compress_batch(int n,
                        const uint8_t **in_bufs, const size_t *in_lens,
                        uint8_t **out_bufs, const size_t *out_caps,
                        size_t *out_lens) {
    if (!g_initialized) sglz_init();
    if (n <= 0) return 0;
    if (n > SGLZ_MAX_BATCH_BLOCKS) return -1;

    /* 复用预分配的 compress device 内存池，避免每次 cudaMalloc/cudaFree */
    uint8_t *d_in = (uint8_t *)g_d_compress_in;
    uint8_t *d_out = (uint8_t *)g_d_compress_out;
    size_t *d_in_lens = (size_t *)g_d_compress_in_lens;
    size_t *d_out_lens = (size_t *)g_d_compress_out_lens;

    /* 异步拷贝所有输入 */
    for (int i = 0; i < n; i++) {
        size_t len = in_lens[i];
        if (len > SGLZ_BLOCK_SIZE) len = SGLZ_BLOCK_SIZE;
        cudaMemcpyAsync(d_in + i * SGLZ_BLOCK_SIZE, in_bufs[i], len, cudaMemcpyHostToDevice, g_streams[0]);
    }
    cudaMemcpyAsync(d_in_lens, in_lens, n * sizeof(size_t), cudaMemcpyHostToDevice, g_streams[0]);
    cudaMemsetAsync(d_out_lens, 0, n * sizeof(size_t), g_streams[0]);

    /* 启动一个 kernel 处理所有 chunks */
    int total_chunks = n * SGLZ_NCHUNKS;
    int threads_per_block = SGLZ_COMPRESS_TPB;
    int num_blocks = (total_chunks + threads_per_block - 1) / threads_per_block;
    size_t shared_mem = threads_per_block * SGLZ_HASH_SIZE * sizeof(int);
    sglz_compress_chunks_kernel<<<num_blocks, threads_per_block, shared_mem, g_streams[0]>>>(d_in, d_out, d_in_lens, d_out_lens, total_chunks);
    cudaStreamSynchronize(g_streams[0]);

    /* 拷回输出长度 */
    size_t *h_out_lens = (size_t *)malloc(n * sizeof(size_t));
    cudaMemcpy(h_out_lens, d_out_lens, n * sizeof(size_t), cudaMemcpyDeviceToHost);

    int success = 0;
    for (int i = 0; i < n; i++) {
        size_t comp_size = h_out_lens[i];
        if (comp_size > 0 && comp_size < in_lens[i] && comp_size <= out_caps[i]) {
            cudaMemcpy(out_bufs[i], d_out + i * SGLZ_NCHUNKS * SGLZ_SLOT_SIZE,
                       SGLZ_NCHUNKS * SGLZ_SLOT_SIZE, cudaMemcpyDeviceToHost);
            out_lens[i] = comp_size;
            success++;
        } else {
            out_lens[i] = 0;
        }
    }

    free(h_out_lens);
    return success;
}

/*
 * 批量解压（优化版）
 */
int sglz_decompress_batch(int n,
                          const uint8_t **in_bufs, const size_t *in_lens,
                          uint8_t **out_bufs, const size_t *out_lens) {
    if (!g_initialized) sglz_init();
    if (n <= 0) return 0;
    if (n > SGLZ_MAX_BATCH_BLOCKS) return -1;
    (void)in_lens;

    /* 使用预分配的 device 内存池，避免 cudaMalloc/cudaFree 开销 */
    uint8_t *d_in = (uint8_t *)g_d_batch_in[0];
    uint8_t *d_out = (uint8_t *)g_d_batch_out[0];
    size_t *d_out_lens = (size_t *)g_d_batch_out_lens[0];

    for (int i = 0; i < n; i++) {
        cudaMemcpyAsync(d_in + i * SGLZ_NCHUNKS * SGLZ_SLOT_SIZE, in_bufs[i],
                        SGLZ_NCHUNKS * SGLZ_SLOT_SIZE, cudaMemcpyHostToDevice, g_streams[0]);
    }
    cudaMemcpyAsync(d_out_lens, out_lens, n * sizeof(size_t), cudaMemcpyHostToDevice, g_streams[0]);

    int total_chunks = n * SGLZ_NCHUNKS;
    int threads_per_block = SGLZ_THREADS_PER_BLOCK;
    int num_blocks = (total_chunks + threads_per_block - 1) / threads_per_block;
    sglz_decompress_chunks_kernel<<<num_blocks, threads_per_block, 0, g_streams[0]>>>(d_in, d_out, d_out_lens, total_chunks);
    cudaStreamSynchronize(g_streams[0]);

    for (int i = 0; i < n; i++) {
        cudaMemcpy(out_bufs[i], d_out + i * SGLZ_BLOCK_SIZE, out_lens[i], cudaMemcpyDeviceToHost);
    }

    return n;
}

/*
 * 批量解压（紧凑格式，零 slot 转换）
 */
int sglz_decompress_batch_compact(int n,
                                   const uint8_t *in_buf, size_t in_total_len,
                                   const int *chunk_offsets,
                                   uint8_t **out_bufs, const size_t *out_lens) {
    if (!g_initialized) sglz_init();
    if (n <= 0) return 0;
    if (n > SGLZ_MAX_BATCH_BLOCKS) return -1;
    /* 复用预分配的 device 内存池（stream 0，同步路径） */
    uint8_t *d_in = (uint8_t *)g_d_batch_in[0];
    uint8_t *d_out = (uint8_t *)g_d_batch_out[0];
    size_t *d_out_lens = (size_t *)g_d_batch_out_lens[0];
    int *d_offsets = (int *)g_d_chunk_offsets[0];

    size_t pool_in_size = (size_t)SGLZ_MAX_BATCH_BLOCKS * SGLZ_NCHUNKS * SGLZ_SLOT_SIZE;
    if (in_total_len > pool_in_size) return -1;

    cudaMemcpyAsync(d_in, in_buf, in_total_len, cudaMemcpyHostToDevice, g_streams[0]);
    cudaMemcpyAsync(d_offsets, chunk_offsets, n * SGLZ_NCHUNKS * sizeof(int),
                    cudaMemcpyHostToDevice, g_streams[0]);
    cudaMemcpyAsync(d_out_lens, out_lens, n * sizeof(size_t), cudaMemcpyHostToDevice, g_streams[0]);

    int total_chunks = n * SGLZ_NCHUNKS;
    int threads_per_block = SGLZ_THREADS_PER_BLOCK;
    int num_blocks = (total_chunks + threads_per_block - 1) / threads_per_block;
    sglz_decompress_compact_kernel<<<num_blocks, threads_per_block, 0, g_streams[0]>>>(
        d_in, d_out, d_offsets, d_out_lens, total_chunks);
    cudaError_t err = cudaStreamSynchronize(g_streams[0]);
    if (err != cudaSuccess) {
        fprintf(stderr, "[COMPACT] kernel sync failed: %s\n", cudaGetErrorString(err));
        return -1;
    }

    for (int i = 0; i < n; i++) {
        cudaMemcpy(out_bufs[i], d_out + i * SGLZ_BLOCK_SIZE, out_lens[i], cudaMemcpyDeviceToHost);
    }

    return n;
}

/*
 * 异步批量解压（紧凑格式）— 提交到指定 stream，不等待完成
 */
int sglz_decompress_batch_compact_async(int n,
                                           const uint8_t *in_buf, size_t in_total_len,
                                           const int *chunk_offsets,
                                           const size_t *out_lens,
                                           int stream_id) {
    if (!g_initialized) sglz_init();
    if (n <= 0) return 0;
    if (n > SGLZ_MAX_BATCH_BLOCKS) return -1;
    if (stream_id < 0 || stream_id >= SGLZ_NUM_STREAMS) return -1;

    cudaStream_t stream = g_streams[stream_id];
    uint8_t *d_in = (uint8_t *)g_d_batch_in[stream_id];
    uint8_t *d_out = (uint8_t *)g_d_batch_out[stream_id];
    size_t *d_out_lens = (size_t *)g_d_batch_out_lens[stream_id];
    int *d_offsets = (int *)g_d_chunk_offsets[stream_id];

    size_t pool_in_size = (size_t)SGLZ_MAX_BATCH_BLOCKS * SGLZ_NCHUNKS * SGLZ_SLOT_SIZE;
    if (in_total_len > pool_in_size) return -1;

    cudaMemcpyAsync(d_in, in_buf, in_total_len, cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(d_offsets, chunk_offsets, n * SGLZ_NCHUNKS * sizeof(int),
                    cudaMemcpyHostToDevice, stream);
    cudaMemcpyAsync(d_out_lens, out_lens, n * sizeof(size_t), cudaMemcpyHostToDevice, stream);

    int total_chunks = n * SGLZ_NCHUNKS;
    int threads_per_block = SGLZ_THREADS_PER_BLOCK;
    int num_blocks = (total_chunks + threads_per_block - 1) / threads_per_block;
    sglz_decompress_compact_kernel<<<num_blocks, threads_per_block, 0, stream>>>(
        d_in, d_out, d_offsets, d_out_lens, total_chunks);

    /* 不 synchronize，不 D2H — 由 wait 完成 */
    return n;
}

/*
 * 等待指定 stream 的异步解压完成，并将结果拷回 host
 */
int sglz_decompress_batch_compact_wait(int stream_id, int n,
                                          uint8_t **out_bufs, const size_t *out_lens) {
    if (stream_id < 0 || stream_id >= SGLZ_NUM_STREAMS) return -1;
    cudaStream_t stream = g_streams[stream_id];
    cudaError_t err = cudaStreamSynchronize(stream);
    if (err != cudaSuccess) {
        fprintf(stderr, "[COMPACT] stream %d sync failed: %s\n", stream_id, cudaGetErrorString(err));
        return -1;
    }

    uint8_t *d_out = (uint8_t *)g_d_batch_out[stream_id];
    for (int i = 0; i < n; i++) {
        cudaMemcpy(out_bufs[i], d_out + i * SGLZ_BLOCK_SIZE, out_lens[i], cudaMemcpyDeviceToHost);
    }
    return n;
}

/* ============================================================
 *  C-compatible wrappers
 * ============================================================ */

extern "C" {

int gpu_compress_init(void) {
    return sglz_init();
}

void gpu_compress_fini(void) {
    sglz_fini();
}

int gpu_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap) {
    return sglz_compress_block(in, out, out_cap);
}

int gpu_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len) {
    return sglz_decompress_block(in, in_len, out, out_len);
}

int gpu_decompress_batch(int n,
                         const uint8_t **in_bufs, const size_t *in_lens,
                         uint8_t **out_bufs, const size_t *out_lens) {
    return sglz_decompress_batch(n, in_bufs, in_lens, out_bufs, out_lens);
}

int gpu_decompress_batch_compact(int n,
                                  const uint8_t *in_buf, size_t in_total_len,
                                  const int *chunk_offsets,
                                  uint8_t **out_bufs, const size_t *out_lens) {
    return sglz_decompress_batch_compact(n, in_buf, in_total_len, chunk_offsets, out_bufs, out_lens);
}

int gpu_decompress_batch_compact_async(int n,
                                        const uint8_t *in_buf, size_t in_total_len,
                                        const int *chunk_offsets,
                                        const size_t *out_lens,
                                        int stream_id) {
    return sglz_decompress_batch_compact_async(n, in_buf, in_total_len, chunk_offsets, out_lens, stream_id);
}

int gpu_decompress_batch_compact_wait(int stream_id, int n,
                                       uint8_t **out_bufs, const size_t *out_lens) {
    return sglz_decompress_batch_compact_wait(stream_id, n, out_bufs, out_lens);
}

/* -------- Pinned Memory allocation for hook TLS buffers -------- */
int gpu_tls_alloc_pinned(void **ptr, size_t size) {
    /* Quick check: if no CUDA device available, silently fall back to malloc */
    int device_count = 0;
    cudaError_t err = cudaGetDeviceCount(&device_count);
    if (err != cudaSuccess || device_count == 0) {
        return -1;
    }
    err = cudaHostAlloc(ptr, size, cudaHostAllocDefault);
    if (err != cudaSuccess) {
        return -1;
    }
    return 0;
}

void gpu_tls_free_pinned(void *ptr) {
    if (ptr) cudaFreeHost(ptr);
}

} /* extern "C" */
