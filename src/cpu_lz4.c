/*
 * cpu_lz4.c - CPU LZ4 backend for GPUC (fallback path)
 *
 * 当 GPU 不可用时，使用系统 liblz4 解压 LZ4 格式的 GPUC 文件。
 * 输出格式与 gpu_lz4.cu 一致：
 *   [1B flag][payload]
 *   flag = 0: raw
 *   flag = 1: LZ4 compressed
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "gpu_compress_api.h"
#include "lz4_minimal.h"

#define LZ4_BLOCK_SIZE (128 * 1024)

int cpu_lz4_init(void) { return 0; }
void cpu_lz4_fini(void) { }

static int cpu_lz4_compress_one(const uint8_t *in, size_t in_len,
                                uint8_t *out, size_t out_cap,
                                size_t *out_len) {
    if (1 + in_len > out_cap) return -1;

    int max_comp = LZ4_compressBound((int)in_len);
    if (max_comp < 0) return -1;
    if ((size_t)(1 + max_comp) > out_cap) return -1;

    int comp_len = LZ4_compress_default((const char *)in, (char *)(out + 1),
                                        (int)in_len, max_comp);
    if (comp_len <= 0) return -1;

    if ((size_t)comp_len < in_len) {
        out[0] = 1;
        *out_len = 1 + (size_t)comp_len;
    } else {
        out[0] = 0;
        memcpy(out + 1, in, in_len);
        *out_len = 1 + in_len;
    }
    return 0;
}

static int cpu_lz4_decompress_one(const uint8_t *in, size_t in_len,
                                  uint8_t *out, size_t out_len) {
    if (in_len == 0 || out_len == 0) return -1;
    uint8_t flag = in[0];
    if (flag == 0) {
        if (in_len - 1 < out_len) return -1;
        memcpy(out, in + 1, out_len);
        return 0;
    }
    if (flag != 1) return -1;

    int ret = LZ4_decompress_safe((const char *)(in + 1), (char *)out,
                                  (int)(in_len - 1), (int)out_len);
    if (ret < 0 || (size_t)ret != out_len) {
        fprintf(stderr, "[cpu_lz4] decompress failed: ret=%d expected=%zu\n", ret, out_len);
        return -1;
    }
    return 0;
}

int cpu_lz4_compress_batch(int n,
                           const uint8_t **in_bufs, const size_t *in_lens,
                           uint8_t **out_bufs, const size_t *out_caps,
                           size_t *out_lens) {
    if (n <= 0) return 0;
    for (int i = 0; i < n; i++) {
        if (cpu_lz4_compress_one(in_bufs[i], in_lens[i], out_bufs[i], out_caps[i], &out_lens[i]) != 0)
            return -1;
    }
    return n;
}

int cpu_lz4_decompress_batch(int n,
                             const uint8_t **in_bufs, const size_t *in_lens,
                             uint8_t **out_bufs, const size_t *out_lens) {
    if (n <= 0) return 0;
    for (int i = 0; i < n; i++) {
        if (cpu_lz4_decompress_one(in_bufs[i], in_lens[i], out_bufs[i], out_lens[i]) != 0)
            return -1;
    }
    return n;
}

int cpu_lz4_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap) {
    size_t out_len = 0;
    if (cpu_lz4_compress_one(in, LZ4_BLOCK_SIZE, out, out_cap, &out_len) != 0) return -1;
    return (int)out_len;
}

int cpu_lz4_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len) {
    return cpu_lz4_decompress_one(in, in_len, out, out_len);
}
