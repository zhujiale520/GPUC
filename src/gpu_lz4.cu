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

int gpu_lz4_init(void) {
    if (g_gpu_lz4_inited) return 0;

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

void gpu_lz4_fini(void) {
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

int gpu_lz4_decompress_batch(int n,
                             const uint8_t **in_bufs, const size_t *in_lens,
                             uint8_t **out_bufs, const size_t *out_lens) {
    if (n <= 0) return 0;

    /* Raw-fallback blocks do not need CUDA. Build one real nvCOMP batch from
     * the compressed subset instead of synchronizing once per block. */
    int m = 0;
    size_t packed_in_bytes = 0, packed_out_bytes = 0, max_out = 0;
    for (int i = 0; i < n; i++) {
        if (!in_bufs[i] || in_lens[i] == 0 || !out_bufs[i] || out_lens[i] == 0)
            return -1;
        if (in_bufs[i][0] == 0) {
            if (in_lens[i] - 1 < out_lens[i]) return -1;
            memcpy(out_bufs[i], in_bufs[i] + 1, out_lens[i]);
        } else if (in_bufs[i][0] == 1) {
            m++;
            packed_in_bytes += in_lens[i] - 1;
            packed_out_bytes += out_lens[i];
            if (out_lens[i] > max_out) max_out = out_lens[i];
        } else {
            return -1;
        }
    }
    if (m == 0) return n;
    if (gpu_lz4_init() != 0) return -1;

    int rc = -1;
    uint8_t *h_packed_in = (uint8_t *)malloc(packed_in_bytes);
    uint8_t *h_packed_out = (uint8_t *)malloc(packed_out_bytes);
    void **h_in_ptrs = (void **)malloc((size_t)m * sizeof(void *));
    void **h_out_ptrs = (void **)malloc((size_t)m * sizeof(void *));
    size_t *h_comp_lens = (size_t *)malloc((size_t)m * sizeof(size_t));
    size_t *h_out_lens = (size_t *)malloc((size_t)m * sizeof(size_t));
    size_t *h_actual = (size_t *)malloc((size_t)m * sizeof(size_t));
    nvcompStatus_t *h_status =
        (nvcompStatus_t *)malloc((size_t)m * sizeof(nvcompStatus_t));
    int *indices = (int *)malloc((size_t)m * sizeof(int));
    void *d_in = NULL, *d_out = NULL, *d_temp = NULL;
    void **d_in_ptrs = NULL, **d_out_ptrs = NULL;
    size_t *d_comp_lens = NULL, *d_out_lens = NULL, *d_actual = NULL;
    nvcompStatus_t *d_status = NULL;
    size_t in_off = 0, out_off = 0, temp_bytes = 0;
    if (!h_packed_in || !h_packed_out || !h_in_ptrs || !h_out_ptrs ||
        !h_comp_lens || !h_out_lens || !h_actual || !h_status || !indices)
        goto cleanup;

    for (int i = 0, j = 0; i < n; i++) {
        if (in_bufs[i][0] != 1) continue;
        size_t comp_len = in_lens[i] - 1;
        memcpy(h_packed_in + in_off, in_bufs[i] + 1, comp_len);
        indices[j] = i;
        h_comp_lens[j] = comp_len;
        h_out_lens[j] = out_lens[i];
        /* Device base addresses are filled after cudaMalloc. */
        h_in_ptrs[j] = (void *)(uintptr_t)in_off;
        h_out_ptrs[j] = (void *)(uintptr_t)out_off;
        in_off += comp_len;
        out_off += out_lens[i];
        j++;
    }

    if (nvcompBatchedLZ4DecompressGetTempSize((size_t)m, max_out, &temp_bytes)
        != nvcompSuccess)
        goto cleanup;
    if (cudaMalloc(&d_in, packed_in_bytes) != cudaSuccess ||
        cudaMalloc(&d_out, packed_out_bytes) != cudaSuccess ||
        cudaMalloc(&d_temp, temp_bytes ? temp_bytes : 1) != cudaSuccess ||
        cudaMalloc(&d_in_ptrs, (size_t)m * sizeof(void *)) != cudaSuccess ||
        cudaMalloc(&d_out_ptrs, (size_t)m * sizeof(void *)) != cudaSuccess ||
        cudaMalloc(&d_comp_lens, (size_t)m * sizeof(size_t)) != cudaSuccess ||
        cudaMalloc(&d_out_lens, (size_t)m * sizeof(size_t)) != cudaSuccess ||
        cudaMalloc(&d_actual, (size_t)m * sizeof(size_t)) != cudaSuccess ||
        cudaMalloc(&d_status, (size_t)m * sizeof(nvcompStatus_t)) != cudaSuccess)
        goto cleanup;

    for (int j = 0; j < m; j++) {
        h_in_ptrs[j] = (uint8_t *)d_in + (uintptr_t)h_in_ptrs[j];
        h_out_ptrs[j] = (uint8_t *)d_out + (uintptr_t)h_out_ptrs[j];
    }
    if (cudaMemcpy(d_in, h_packed_in, packed_in_bytes, cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(d_in_ptrs, h_in_ptrs, (size_t)m * sizeof(void *), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(d_out_ptrs, h_out_ptrs, (size_t)m * sizeof(void *), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(d_comp_lens, h_comp_lens, (size_t)m * sizeof(size_t), cudaMemcpyHostToDevice) != cudaSuccess ||
        cudaMemcpy(d_out_lens, h_out_lens, (size_t)m * sizeof(size_t), cudaMemcpyHostToDevice) != cudaSuccess)
        goto cleanup;

    if (nvcompBatchedLZ4DecompressAsync(
            (const void *const *)d_in_ptrs, d_comp_lens, d_out_lens,
            d_actual, (size_t)m, d_temp, temp_bytes,
            d_out_ptrs, d_status, 0) != nvcompSuccess ||
        cudaStreamSynchronize(0) != cudaSuccess ||
        cudaMemcpy(h_actual, d_actual, (size_t)m * sizeof(size_t), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(h_status, d_status, (size_t)m * sizeof(nvcompStatus_t), cudaMemcpyDeviceToHost) != cudaSuccess ||
        cudaMemcpy(h_packed_out, d_out, packed_out_bytes, cudaMemcpyDeviceToHost) != cudaSuccess)
        goto cleanup;

    out_off = 0;
    for (int j = 0; j < m; j++) {
        int i = indices[j];
        if (h_status[j] != nvcompSuccess || h_actual[j] != out_lens[i])
            goto cleanup;
        memcpy(out_bufs[i], h_packed_out + out_off, out_lens[i]);
        out_off += out_lens[i];
    }
    rc = n;

cleanup:
    if (d_in) cudaFree(d_in);
    if (d_out) cudaFree(d_out);
    if (d_temp) cudaFree(d_temp);
    if (d_in_ptrs) cudaFree(d_in_ptrs);
    if (d_out_ptrs) cudaFree(d_out_ptrs);
    if (d_comp_lens) cudaFree(d_comp_lens);
    if (d_out_lens) cudaFree(d_out_lens);
    if (d_actual) cudaFree(d_actual);
    if (d_status) cudaFree(d_status);
    free(h_packed_in);
    free(h_packed_out);
    free(h_in_ptrs);
    free(h_out_ptrs);
    free(h_comp_lens);
    free(h_out_lens);
    free(h_actual);
    free(h_status);
    free(indices);
    if (rc < 0) fprintf(stderr, "[gpu_lz4] batched decompress failed\n");
    return rc;
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
