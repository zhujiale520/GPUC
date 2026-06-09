#ifndef GPU_COMPRESS_CUH
#define GPU_COMPRESS_CUH

#include <cuda_runtime.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * GPU 压缩/解压接口（C 兼容）
 * 
 * 设计：
 *   - 128KB 为一块，由 32 个 4KB chunk 组成
 *   - 每个 CUDA thread 处理一个 4KB chunk，充分发挥 GPU 并行度
 *   - 压缩 kernel 使用 shared memory hash 表（stride layout 避免 bank conflict）
 *   - 所有 CUDA 操作通过 stream 异步执行，减少同步开销
 *   - 如果 chunk 压缩后变大，则标记为未压缩（存储原始数据）
 */

#define SGLZ_CHUNK_SIZE   4096
#define SGLZ_NCHUNKS      32       /* 32 * 4KB = 128KB */
#define SGLZ_BLOCK_SIZE   (SGLZ_CHUNK_SIZE * SGLZ_NCHUNKS)  /* 128KB */
#define SGLZ_HASH_BITS    8
#define SGLZ_HASH_SIZE    (1 << SGLZ_HASH_BITS)
#define SGLZ_MIN_MATCH    4
#define SGLZ_MAX_MATCH    255
#define SGLZ_MAX_OFFSET   2048

/* 每个 chunk 压缩后的最大可能大小（略大于原始大小，用于分配缓冲区） */
#define SGLZ_MAX_COMP_SIZE (SGLZ_CHUNK_SIZE + 256)

/* CUDA kernel 启动参数 */
#define SGLZ_THREADS_PER_BLOCK  256
#define SGLZ_WARPS_PER_BLOCK    (SGLZ_THREADS_PER_BLOCK / 32)  /* 8 warps */

/* 初始化/释放 CUDA 资源 */
int  sglz_init(void);
void sglz_fini(void);

/*
 * 压缩单个 128KB 块
 * 
 * @param in_buf   输入数据（Host pinned memory 或 managed memory）
 * @param out_buf  输出缓冲区（Host pinned memory）
 * @param out_cap  输出缓冲区容量
 * @return 压缩后总大小（含 chunk 头），如果所有 chunk 都不可压缩则返回 0
 */
int sglz_compress_block(const uint8_t *in_buf, uint8_t *out_buf, size_t out_cap);

/*
 * 解压单个 128KB 块
 * 
 * @param in_buf   压缩数据（Host pinned memory）
 * @param in_len   压缩数据长度
 * @param out_buf  输出缓冲区（Host pinned memory）
 * @param out_len  预期输出大小（128KB 或最后一块的剩余大小）
 * @return 0 成功，-1 失败
 */
int sglz_decompress_block(const uint8_t *in_buf, size_t in_len,
                          uint8_t *out_buf, size_t out_len);

/*
 * 批量压缩多个 128KB 块（用于 Daemon）
 * 
 * @param n        块数量
 * @param in_bufs  输入数据数组（每个 128KB 或最后一块可能不足）
 * @param in_lens  每个输入块的实际大小
 * @param out_bufs 输出缓冲区数组
 * @param out_caps 每个输出缓冲区容量
 * @param out_lens 返回每个块的压缩后大小（0 表示未压缩）
 * @return 成功压缩的块数
 */
int sglz_compress_batch(int n,
                        const uint8_t **in_bufs, const size_t *in_lens,
                        uint8_t **out_bufs, const size_t *out_caps,
                        size_t *out_lens);

/*
 * 批量解压多个块（用于 read 路径）
 * 
 * @param n        块数量
 * @param in_bufs  压缩数据数组
 * @param in_lens  每个压缩数据长度
 * @param out_bufs 输出缓冲区数组
 * @param out_lens 每个输出预期大小
 * @return 成功解压的块数
 */
int sglz_decompress_batch(int n,
                          const uint8_t **in_bufs, const size_t *in_lens,
                          uint8_t **out_bufs, const size_t *out_lens);

/*
 * 批量解压（紧凑格式，零 slot 转换）
 *
 * @param n            块数量
 * @param in_buf       所有块的紧凑数据连续存放（Host memory）
 * @param in_total_len in_buf 总字节数
 * @param chunk_offsets 每个 chunk 在 in_buf 中的偏移，大小 = n * SGLZ_NCHUNKS
 * @param out_bufs     输出缓冲区数组
 * @param out_lens     每个输出预期大小
 * @return 成功解压的块数
 */
int sglz_decompress_batch_compact(int n,
                                   const uint8_t *in_buf, size_t in_total_len,
                                   const int *chunk_offsets,
                                   uint8_t **out_bufs, const size_t *out_lens);

#ifdef __cplusplus
}
#endif

#endif /* GPU_COMPRESS_CUH */
