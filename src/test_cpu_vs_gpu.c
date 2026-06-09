/*
 * test_cpu_vs_gpu.c - CPU vs GPU 压缩/解压性能对比测试
 *
 * 测试维度：
 *   1. CPU 串行（逐块）
 *   2. GPU 单次（逐块 cudaMalloc，旧方式）
 *   3. GPU 批量（batch，一次性处理所有块，优化方式）
 *   4. 压缩率一致性
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "gpu_compress_api.h"

/* CPU API */
int  cpu_compress_init(void);
void cpu_compress_fini(void);
int  cpu_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap);
int  cpu_decompress_128k(const uint8_t *in, size_t in_len, uint8_t *out, size_t out_len);

/* GPU batch API */
int sglz_compress_batch(int n,
                        const uint8_t **in_bufs, const size_t *in_lens,
                        uint8_t **out_bufs, const size_t *out_caps,
                        size_t *out_lens);
int sglz_decompress_batch(int n,
                          const uint8_t **in_bufs, const size_t *in_lens,
                          uint8_t **out_bufs, const size_t *out_lens);

#define BLOCK_SIZE  (128 * 1024)
#define NUM_BLOCKS  512          /* 64 MB 总数据 */
#define TOTAL_SIZE  (BLOCK_SIZE * NUM_BLOCKS)

static double get_time_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static void generate_compressible(uint8_t *buf, size_t size) {
    for (size_t i = 0; i < size; i++) {
        buf[i] = (uint8_t)((i / 4096) + (i % 256));
    }
}

static void generate_zeros(uint8_t *buf, size_t size) {
    memset(buf, 0, size);
}

static void generate_random(uint8_t *buf, size_t size) {
    srand(42);
    for (size_t i = 0; i < size; i++) {
        buf[i] = (uint8_t)rand();
    }
}

static int run_benchmark(const char *label,
                         uint8_t *src,
                         uint8_t **gpu_comp,
                         uint8_t **cpu_comp,
                         uint8_t *decomp) {
    printf("\n=== Benchmark: %s ===\n", label);

    size_t in_lens[NUM_BLOCKS];
    size_t out_caps[NUM_BLOCKS];
    size_t out_lens[NUM_BLOCKS];
    for (int i = 0; i < NUM_BLOCKS; i++) {
        in_lens[i] = BLOCK_SIZE;
        out_caps[i] = GC_NCHUNKS * GC_SLOT_SIZE;
    }

    /* -------- CPU 串行压缩 -------- */
    double t0 = get_time_sec();
    int cpu_total_comp = 0;
    for (int i = 0; i < NUM_BLOCKS; i++) {
        int ret = cpu_compress_128k(src + i * BLOCK_SIZE, cpu_comp[i], GC_NCHUNKS * GC_SLOT_SIZE);
        if (ret > 0) cpu_total_comp += ret;
        else cpu_total_comp += BLOCK_SIZE;
    }
    double cpu_comp_time = get_time_sec() - t0;
    double cpu_comp_bw = (TOTAL_SIZE / (1024.0 * 1024.0)) / cpu_comp_time;

    /* -------- GPU 单次压缩（旧方式，逐块） -------- */
    t0 = get_time_sec();
    int gpu_single_total = 0;
    for (int i = 0; i < NUM_BLOCKS; i++) {
        int ret = gpu_compress_128k(src + i * BLOCK_SIZE, gpu_comp[i], GC_NCHUNKS * GC_SLOT_SIZE);
        if (ret > 0) gpu_single_total += ret;
        else gpu_single_total += BLOCK_SIZE;
    }
    double gpu_single_time = get_time_sec() - t0;
    double gpu_single_bw = (TOTAL_SIZE / (1024.0 * 1024.0)) / gpu_single_time;

    /* -------- GPU 批量压缩（batch，优化方式） -------- */
    const uint8_t *in_ptrs[NUM_BLOCKS];
    uint8_t *out_ptrs[NUM_BLOCKS];
    for (int i = 0; i < NUM_BLOCKS; i++) {
        in_ptrs[i] = src + i * BLOCK_SIZE;
        out_ptrs[i] = gpu_comp[i];
    }
    t0 = get_time_sec();
    sglz_compress_batch(NUM_BLOCKS, in_ptrs, in_lens, out_ptrs, out_caps, out_lens);
    int gpu_batch_total = 0;
    for (int i = 0; i < NUM_BLOCKS; i++) {
        if (out_lens[i] > 0) gpu_batch_total += (int)out_lens[i];
        else gpu_batch_total += BLOCK_SIZE;
    }
    double gpu_batch_time = get_time_sec() - t0;
    double gpu_batch_bw = (TOTAL_SIZE / (1024.0 * 1024.0)) / gpu_batch_time;

    printf("  Compression ratio: CPU %.2f%%  GPU(single) %.2f%%  GPU(batch) %.2f%%\n",
           100.0 * cpu_total_comp / TOTAL_SIZE,
           100.0 * gpu_single_total / TOTAL_SIZE,
           100.0 * gpu_batch_total / TOTAL_SIZE);

    /* -------- CPU 解压 -------- */
    t0 = get_time_sec();
    for (int i = 0; i < NUM_BLOCKS; i++) {
        cpu_decompress_128k(cpu_comp[i], GC_NCHUNKS * GC_SLOT_SIZE,
                            decomp + i * BLOCK_SIZE, BLOCK_SIZE);
    }
    double cpu_decomp_time = get_time_sec() - t0;
    double cpu_decomp_bw = (TOTAL_SIZE / (1024.0 * 1024.0)) / cpu_decomp_time;
    if (memcmp(src, decomp, TOTAL_SIZE) != 0) {
        printf("  ERROR: CPU decompress mismatch!\n");
        return -1;
    }

    /* -------- GPU 批量解压 -------- */
    size_t decomp_lens[NUM_BLOCKS];
    for (int i = 0; i < NUM_BLOCKS; i++) decomp_lens[i] = BLOCK_SIZE;
    uint8_t *decomp_ptrs[NUM_BLOCKS];
    for (int i = 0; i < NUM_BLOCKS; i++) decomp_ptrs[i] = decomp + i * BLOCK_SIZE;

    t0 = get_time_sec();
    sglz_decompress_batch(NUM_BLOCKS, (const uint8_t **)out_ptrs, in_lens,
                          decomp_ptrs, decomp_lens);
    double gpu_decomp_time = get_time_sec() - t0;
    double gpu_decomp_bw = (TOTAL_SIZE / (1024.0 * 1024.0)) / gpu_decomp_time;
    if (memcmp(src, decomp, TOTAL_SIZE) != 0) {
        printf("  ERROR: GPU decompress mismatch!\n");
        return -1;
    }

    /* -------- Report -------- */
    printf("  CPU compress:   %.3f s  =>  %8.1f MB/s\n", cpu_comp_time, cpu_comp_bw);
    printf("  GPU compress(single): %.3f s  =>  %8.1f MB/s\n", gpu_single_time, gpu_single_bw);
    printf("  GPU compress(batch):  %.3f s  =>  %8.1f MB/s\n", gpu_batch_time, gpu_batch_bw);
    printf("  Speedup (batch vs CPU): %.2fx\n", gpu_batch_bw / cpu_comp_bw);
    printf("  CPU decompress: %.3f s  =>  %8.1f MB/s\n", cpu_decomp_time, cpu_decomp_bw);
    printf("  GPU decompress: %.3f s  =>  %8.1f MB/s\n", gpu_decomp_time, gpu_decomp_bw);
    printf("  Speedup (decomp): %.2fx\n", gpu_decomp_bw / cpu_decomp_bw);

    return 0;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    printf("=== CPU vs GPU Compression Benchmark ===\n");
    printf("Data size: %d MB (%d x 128KB blocks)\n",
           TOTAL_SIZE / (1024 * 1024), NUM_BLOCKS);

    if (gpu_compress_init() != 0) {
        fprintf(stderr, "GPU init failed\n");
        return 1;
    }
    cpu_compress_init();

    uint8_t *src = (uint8_t *)aligned_alloc(4096, TOTAL_SIZE);
    uint8_t *decomp = (uint8_t *)aligned_alloc(4096, TOTAL_SIZE);
    uint8_t **gpu_comp = (uint8_t **)malloc(NUM_BLOCKS * sizeof(uint8_t *));
    uint8_t **cpu_comp = (uint8_t **)malloc(NUM_BLOCKS * sizeof(uint8_t *));

    for (int i = 0; i < NUM_BLOCKS; i++) {
        gpu_comp[i] = (uint8_t *)aligned_alloc(4096, GC_NCHUNKS * GC_SLOT_SIZE);
        cpu_comp[i] = (uint8_t *)aligned_alloc(4096, GC_NCHUNKS * GC_SLOT_SIZE);
    }

    int failures = 0;

    generate_compressible(src, TOTAL_SIZE);
    failures += run_benchmark("Compressible (repetitive)", src, gpu_comp, cpu_comp, decomp);

    generate_zeros(src, TOTAL_SIZE);
    failures += run_benchmark("All-zeros", src, gpu_comp, cpu_comp, decomp);

    generate_random(src, TOTAL_SIZE);
    failures += run_benchmark("Random (incompressible)", src, gpu_comp, cpu_comp, decomp);

    free(src); free(decomp);
    for (int i = 0; i < NUM_BLOCKS; i++) {
        free(gpu_comp[i]); free(cpu_comp[i]);
    }
    free(gpu_comp); free(cpu_comp);

    gpu_compress_fini();
    cpu_compress_fini();

    if (failures == 0) {
        printf("\n=== ALL BENCHMARKS PASSED ===\n");
        return 0;
    } else {
        printf("\n=== %d BENCHMARK(S) FAILED ===\n", failures);
        return 1;
    }
}
