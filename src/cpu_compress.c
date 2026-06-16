/*
 * cpu_compress.c - Pure CPU implementation of SGLZ (Simple GPU LZ)
 *
 * 用途：作为 GPU offload 方案的对比基准，体现 "纯 CPU 实现" 的性能开销。
 * 算法与 gpu_compress.cu 完全一致，仅在 CPU 上串行执行。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* 从 gpu_compress.cuh 复制所需常量（避免依赖 CUDA 头文件） */
#define SGLZ_CHUNK_SIZE   4096
#define SGLZ_NCHUNKS      32
#define SGLZ_BLOCK_SIZE   (SGLZ_CHUNK_SIZE * SGLZ_NCHUNKS)
#define SGLZ_HASH_BITS    8
#define SGLZ_HASH_SIZE    (1 << SGLZ_HASH_BITS)
#define SGLZ_MIN_MATCH    4
#define SGLZ_MAX_MATCH    255
#define SGLZ_MAX_OFFSET   2048
#define SGLZ_SLOT_SIZE    (SGLZ_CHUNK_SIZE + 256)
#define SGLZ_MAX_BATCH_BLOCKS 32

/* ============================================================
 *  CPU-side compression (single chunk)
 * ============================================================ */

static inline uint32_t sglz_hash3_cpu(const uint8_t *p) {
    return ((uint32_t)p[0] * 31 + (uint32_t)p[1] * 17 + (uint32_t)p[2]) & (SGLZ_HASH_SIZE - 1);
}

static int sglz_compress_chunk_cpu(const uint8_t *src, uint8_t *dst, int src_len) {
    int hash_tbl[SGLZ_HASH_SIZE];
    for (int h = 0; h < SGLZ_HASH_SIZE; h++) hash_tbl[h] = -1;

    uint8_t *out = dst + 2;
    int out_pos = 0;
    int i = 0;

    while (i < src_len) {
        int best_len = 0;
        int best_off = 0;

        if (i + SGLZ_MIN_MATCH <= src_len) {
            uint32_t h = sglz_hash3_cpu(&src[i]);
            int prev = hash_tbl[h];
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
            hash_tbl[h] = i;
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
                    uint32_t h = sglz_hash3_cpu(&src[i]);
                    int prev = hash_tbl[h];
                    if (prev >= 0 && (i - prev) <= SGLZ_MAX_OFFSET && src[prev] == src[i])
                        break;
                    hash_tbl[h] = i;
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
 *  CPU-side decompression (single chunk)
 * ============================================================ */

static int sglz_decompress_chunk_cpu(const uint8_t *src, uint8_t *dst, int dst_len) {
    uint16_t comp_len = *(const uint16_t *)src;
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
            int len = src[in_pos] | (src[in_pos + 1] << 8);
            in_pos += 2;
            for (int k = 0; k < len && out_pos < dst_len; k++)
                dst[out_pos++] = src[in_pos++];
        } else if (tag == 0x01) {
            int off = src[in_pos] | (src[in_pos + 1] << 8);
            in_pos += 2;
            int len = src[in_pos] | (src[in_pos + 1] << 8);
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
 *  Host-side wrappers (same API as GPU version)
 * ============================================================ */

int cpu_compress_block(const uint8_t *in_buf, uint8_t *out_buf, size_t out_cap) {
    (void)out_cap; /* caller guarantees enough space */

    int total_comp = 0;
    for (int j = 0; j < SGLZ_NCHUNKS; j++) {
        int chunk_off = j * SGLZ_CHUNK_SIZE;
        int chunk_len = (chunk_off + SGLZ_CHUNK_SIZE <= SGLZ_BLOCK_SIZE)
                            ? SGLZ_CHUNK_SIZE
                            : SGLZ_BLOCK_SIZE - chunk_off;
        uint8_t *slot = out_buf + j * SGLZ_SLOT_SIZE;
        int cs = sglz_compress_chunk_cpu(in_buf + chunk_off, slot, chunk_len);
        total_comp += cs;
    }

    if (total_comp == 0 || total_comp >= SGLZ_BLOCK_SIZE) {
        return 0; /* uncompressible */
    }
    return total_comp;
}

int cpu_decompress_block(const uint8_t *in_buf, size_t in_len,
                         uint8_t *out_buf, size_t out_len) {
    (void)in_len;
    for (int j = 0; j < SGLZ_NCHUNKS; j++) {
        int chunk_off = j * SGLZ_CHUNK_SIZE;
        int chunk_out_len = (chunk_off + SGLZ_CHUNK_SIZE <= (int)out_len)
                                ? SGLZ_CHUNK_SIZE
                                : (int)out_len - chunk_off;
        if (chunk_out_len <= 0) break;
        const uint8_t *slot = in_buf + j * SGLZ_SLOT_SIZE;
        sglz_decompress_chunk_cpu(slot, out_buf + chunk_off, chunk_out_len);
    }
    return 0;
}

/* ============================================================
 *  C-compatible public API
 * ============================================================ */

int cpu_compress_init(void) {
    /* CPU version needs no special init */
    return 0;
}

void cpu_compress_fini(void) {
    /* nothing to clean up */
}

int cpu_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap) {
    return cpu_compress_block(in, out, out_cap);
}

int cpu_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len) {
    return cpu_decompress_block(in, in_len, out, out_len);
}

int cpu_decompress_batch(int n,
                         const uint8_t **in_bufs, const size_t *in_lens,
                         uint8_t **out_bufs, const size_t *out_lens) {
    for (int i = 0; i < n; i++) {
        cpu_decompress_block(in_bufs[i], in_lens[i], out_bufs[i], out_lens[i]);
    }
    return n;
}

/*
 * Compact-format batch decompress: each chunk is addressed via chunk_offsets
 * without requiring slot-layout padding. Input is still logically slot-formatted
 * (2-byte length prefix per chunk), just packed tightly.
 */
int cpu_decompress_batch_compact(int n,
                                  const uint8_t *in_buf, size_t in_total_len,
                                  const int *chunk_offsets,
                                  uint8_t **out_bufs, const size_t *out_lens) {
    (void)in_total_len;
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < SGLZ_NCHUNKS; j++) {
            int chunk_off = j * SGLZ_CHUNK_SIZE;
            int chunk_out_len = (chunk_off + SGLZ_CHUNK_SIZE <= (int)out_lens[i])
                                    ? SGLZ_CHUNK_SIZE
                                    : (int)out_lens[i] - chunk_off;
            if (chunk_out_len <= 0) break;
            const uint8_t *slot = in_buf + chunk_offsets[i * SGLZ_NCHUNKS + j];
            sglz_decompress_chunk_cpu(slot, out_bufs[i] + chunk_off, chunk_out_len);
        }
    }
    return n;
}

/* ============================================================
 *  Async pipeline stubs (CPU backend: no real async, just deferred execution)
 * ============================================================ */

typedef struct {
    int valid;
    int n;
    uint8_t comp_buf[SGLZ_MAX_BATCH_BLOCKS * SGLZ_NCHUNKS * SGLZ_SLOT_SIZE];
    int chunk_offsets[SGLZ_MAX_BATCH_BLOCKS * SGLZ_NCHUNKS];
    size_t out_lens[SGLZ_MAX_BATCH_BLOCKS];
} cpu_pending_t;

static cpu_pending_t g_cpu_pending[2];

int cpu_decompress_batch_compact_async(int n,
                                        const uint8_t *in_buf, size_t in_total_len,
                                        const int *chunk_offsets,
                                        const size_t *out_lens,
                                        int stream_id) {
    if (stream_id < 0 || stream_id >= 2) return -1;
    cpu_pending_t *p = &g_cpu_pending[stream_id];
    p->valid = 1;
    p->n = n;
    if (in_total_len > sizeof(p->comp_buf)) return -1;
    memcpy(p->comp_buf, in_buf, in_total_len);
    memcpy(p->chunk_offsets, chunk_offsets, n * SGLZ_NCHUNKS * sizeof(int));
    memcpy(p->out_lens, out_lens, n * sizeof(size_t));
    return n;
}

int cpu_decompress_batch_compact_wait(int stream_id, int n,
                                       uint8_t **out_bufs, const size_t *out_lens) {
    (void)n;
    if (stream_id < 0 || stream_id >= 2) return -1;
    cpu_pending_t *p = &g_cpu_pending[stream_id];
    if (!p->valid) return -1;
    int ret = cpu_decompress_batch_compact(p->n, p->comp_buf, 0,
                                            p->chunk_offsets, out_bufs, p->out_lens);
    p->valid = 0;
    return ret;
}
