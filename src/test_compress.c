/*
 * test_compress.c - GPU 压缩/解压单元测试
 *
 * 测试内容：
 *   1. 可压缩数据（重复模式）的压缩/解压一致性
 *   2. 不可压缩数据（随机数据）的 fallback
 *   3. 多轮压缩/解压稳定性
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#include "gpu_compress_api.h"

#define TEST_SIZE  (128 * 1024)

static int test_compressible_data(void) {
    printf("[TEST] Compressing repetitive data...\n");

    uint8_t *src = (uint8_t *)malloc(TEST_SIZE);
    uint8_t *comp = (uint8_t *)malloc(GC_NCHUNKS * GC_SLOT_SIZE);
    uint8_t *decomp = (uint8_t *)malloc(TEST_SIZE);

    /* 生成可压缩数据：每 4KB 重复相同模式 */
    for (int i = 0; i < TEST_SIZE; i++) {
        src[i] = (uint8_t)((i / 4096) + (i % 256));
    }

    int comp_size = gpu_compress_128k(src, comp, GC_NCHUNKS * GC_SLOT_SIZE);
    printf("[TEST] Compressed: %d -> %d bytes (%.1f%%)\n",
           TEST_SIZE, comp_size, 100.0 * comp_size / TEST_SIZE);

    if (comp_size <= 0 || comp_size >= TEST_SIZE) {
        printf("[TEST] FAIL: compression did not reduce size\n");
        free(src); free(comp); free(decomp);
        return -1;
    }

    /* 解压（gpu_compress_128k 输出已是 slot 布局） */
    if (gpu_decompress_128k(comp, GC_NCHUNKS * GC_SLOT_SIZE, decomp, TEST_SIZE) != 0) {
        printf("[TEST] FAIL: decompression error\n");
        free(src); free(comp); free(decomp);
        return -1;
    }

    /* 验证 */
    if (memcmp(src, decomp, TEST_SIZE) != 0) {
        printf("[TEST] FAIL: data mismatch after round-trip\n");
        free(src); free(comp); free(decomp);
        return -1;
    }

    printf("[TEST] PASS: repetitive data OK\n");
    free(src); free(comp); free(decomp);
    return 0;
}

static int test_random_data(void) {
    printf("[TEST] Compressing random data...\n");

    uint8_t *src = (uint8_t *)malloc(TEST_SIZE);
    uint8_t *comp = (uint8_t *)malloc(GC_NCHUNKS * GC_SLOT_SIZE);

    srand((unsigned)time(NULL));
    for (int i = 0; i < TEST_SIZE; i++) {
        src[i] = (uint8_t)rand();
    }

    int comp_size = gpu_compress_128k(src, comp, GC_NCHUNKS * GC_SLOT_SIZE);
    printf("[TEST] Random data: %d -> %d bytes (%.1f%%)\n",
           TEST_SIZE, comp_size, 100.0 * comp_size / TEST_SIZE);

    if (comp_size != 0) {
        printf("[TEST] FAIL: random data should not compress\n");
        free(src); free(comp);
        return -1;
    }

    printf("[TEST] PASS: random data fallback OK\n");
    free(src); free(comp);
    return 0;
}

static int test_zero_data(void) {
    printf("[TEST] Compressing all-zero data...\n");

    uint8_t *src = (uint8_t *)calloc(1, TEST_SIZE);
    uint8_t *comp = (uint8_t *)malloc(GC_NCHUNKS * GC_SLOT_SIZE);
    uint8_t *decomp = (uint8_t *)malloc(TEST_SIZE);


    int comp_size = gpu_compress_128k(src, comp, GC_NCHUNKS * GC_SLOT_SIZE);
    printf("[TEST] Zero data: %d -> %d bytes (%.1f%%)\n",
           TEST_SIZE, comp_size, 100.0 * comp_size / TEST_SIZE);

    if (comp_size <= 0) {
        printf("[TEST] FAIL: zero data should compress well\n");
        free(src); free(comp); free(decomp);
        return -1;
    }

    if (gpu_decompress_128k(comp, GC_NCHUNKS * GC_SLOT_SIZE, decomp, TEST_SIZE) != 0) {
        printf("[TEST] FAIL: decompression error\n");
        free(src); free(comp); free(decomp);
        return -1;
    }

    if (memcmp(src, decomp, TEST_SIZE) != 0) {
        printf("[TEST] FAIL: data mismatch\n");
        free(src); free(comp); free(decomp);
        return -1;
    }

    printf("[TEST] PASS: zero data OK\n");
    free(src); free(comp); free(decomp);
    return 0;
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    printf("=== GPU Compress Unit Tests ===\n");

    if (gpu_compress_init() != 0) {
        fprintf(stderr, "Failed to initialize GPU\n");
        return 1;
    }

    int failures = 0;
    failures += test_compressible_data();
    failures += test_random_data();
    failures += test_zero_data();

    gpu_compress_fini();

    if (failures == 0) {
        printf("=== ALL TESTS PASSED ===\n");
        return 0;
    } else {
        printf("=== %d TEST(S) FAILED ===\n", failures);
        return 1;
    }
}
