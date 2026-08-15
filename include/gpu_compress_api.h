#ifndef GPU_COMPRESS_API_H
#define GPU_COMPRESS_API_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * GPU/CPU 压缩/解压 C API（不依赖 CUDA 头文件，可被纯 C 代码包含）
 *
 * 这些常量必须与 gpu_compress.cuh / gpu_compress.cu 保持一致。
 */

#define GC_BLOCK_SIZE   (128 * 1024)
#define GC_CHUNK_SIZE   4096
#define GC_NCHUNKS      32
#define GC_SLOT_SIZE    (GC_CHUNK_SIZE + 256)

/* ========== GPU Backend API ========== */
int  gpu_compress_init(void);
void gpu_compress_fini(void);
int gpu_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap);
int gpu_compress_batch(int n,
                       const uint8_t **in_bufs, const size_t *in_lens,
                       uint8_t **out_bufs, const size_t *out_caps,
                       size_t *out_lens);
int gpu_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len);
int gpu_decompress_batch(int n,
                         const uint8_t **in_bufs, const size_t *in_lens,
                         uint8_t **out_bufs, const size_t *out_lens);

/* ========== CPU Backend API（对比基准，同算法）========== */
int  cpu_compress_init(void);
void cpu_compress_fini(void);
int cpu_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap);
int cpu_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len);
int cpu_decompress_batch(int n,
                         const uint8_t **in_bufs, const size_t *in_lens,
                         uint8_t **out_bufs, const size_t *out_lens);

/* ========== LZ4 backend (nvCOMP GPU / liblz4 CPU) ========== */
int  gpu_lz4_init(void);
void gpu_lz4_fini(void);
int gpu_lz4_compress_batch(int n,
                           const uint8_t **in_bufs, const size_t *in_lens,
                           uint8_t **out_bufs, const size_t *out_caps,
                           size_t *out_lens);
int gpu_lz4_decompress_batch(int n,
                             const uint8_t **in_bufs, const size_t *in_lens,
                             uint8_t **out_bufs, const size_t *out_lens);

typedef struct gpu_lz4_profile {
    double queue_ms;
    double pack_ms;
    double h2d_ms;
    double kernel_ms;
    double d2h_ms;
    double unpack_ms;
    double total_ms;
    double worker_user_ms;
    double worker_sys_ms;
    size_t compressed_blocks;
    size_t input_bytes;
    size_t output_bytes;
} gpu_lz4_profile_t;

/* 返回当前调用线程最近一次 gpu_lz4_decompress_batch() 的分阶段计时。 */
int gpu_lz4_get_last_profile(gpu_lz4_profile_t *profile);
int gpu_lz4_host_alloc(void **ptr, size_t size);
void gpu_lz4_host_free(void *ptr);
int gpu_lz4_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap);
int gpu_lz4_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len);

int  cpu_lz4_init(void);
void cpu_lz4_fini(void);
int cpu_lz4_compress_batch(int n,
                           const uint8_t **in_bufs, const size_t *in_lens,
                           uint8_t **out_bufs, const size_t *out_caps,
                           size_t *out_lens);
int cpu_lz4_decompress_batch(int n,
                             const uint8_t **in_bufs, const size_t *in_lens,
                             uint8_t **out_bufs, const size_t *out_lens);
int cpu_lz4_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap);
int cpu_lz4_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len);

/* ========== Compact-format batch decompress (zero slot conversion) ========== */
int gpu_decompress_batch_compact(int n,
                                  const uint8_t *in_buf, size_t in_total_len,
                                  const int *chunk_offsets,
                                  uint8_t **out_bufs, const size_t *out_lens);
int cpu_decompress_batch_compact(int n,
                                  const uint8_t *in_buf, size_t in_total_len,
                                  const int *chunk_offsets,
                                  uint8_t **out_bufs, const size_t *out_lens);

/* ========== Async pipeline batch decompress (overlap I/O with GPU compute) ========== */
int gpu_decompress_batch_compact_async(int n,
                                        const uint8_t *in_buf, size_t in_total_len,
                                        const int *chunk_offsets,
                                        const size_t *out_lens,
                                        int stream_id);
int gpu_decompress_batch_compact_wait(int stream_id, int n,
                                       uint8_t **out_bufs, const size_t *out_lens);
int gpu_tls_alloc_pinned(void **ptr, size_t size);
void gpu_tls_free_pinned(void *ptr);
int cpu_decompress_batch_compact_async(int n,
                                        const uint8_t *in_buf, size_t in_total_len,
                                        const int *chunk_offsets,
                                        const size_t *out_lens,
                                        int stream_id);
int cpu_decompress_batch_compact_wait(int stream_id, int n,
                                       uint8_t **out_bufs, const size_t *out_lens);

#ifdef __cplusplus
}
#endif

#endif /* GPU_COMPRESS_API_H */
