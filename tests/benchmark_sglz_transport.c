#define _POSIX_C_SOURCE 200809L
#include "gpu_compress_api.h"

#include <errno.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static long env_long(const char *name, long fallback, long minimum, long maximum) {
    const char *text = getenv(name);
    if (!text || !*text) return fallback;
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno || !end || *end || value < minimum || value > maximum) {
        fprintf(stderr, "invalid %s=%s (expected %ld..%ld)\n",
                name, text, minimum, maximum);
        exit(2);
    }
    return value;
}

static void fill_pattern(uint8_t *buf, size_t len, int seed) {
    for (size_t i = 0; i < len; i++)
        buf[i] = (uint8_t)(((i / 64) + (size_t)seed) & 15);
}

int main(void) {
    const long logical_mib = env_long("GPUC_PERF_MIB", 1024, 4, 1048576);
    const long iterations = env_long("GPUC_PERF_ITERATIONS", 3, 1, 10000);
    const int batch = (int)env_long("GPUC_PERF_BATCH", 32, 1, 32);
    const size_t slot_bytes = (size_t)GC_NCHUNKS * GC_SLOT_SIZE;
    const uint64_t total_bytes = (uint64_t)logical_mib * 1024 * 1024;
    const uint64_t total_blocks = (total_bytes + GC_BLOCK_SIZE - 1) / GC_BLOCK_SIZE;

    const uint8_t **inputs = calloc((size_t)batch, sizeof(*inputs));
    uint8_t **compressed = calloc((size_t)batch, sizeof(*compressed));
    uint8_t **restored = calloc((size_t)batch, sizeof(*restored));
    size_t *input_lens = calloc((size_t)batch, sizeof(*input_lens));
    size_t *output_caps = calloc((size_t)batch, sizeof(*output_caps));
    size_t *compressed_lens = calloc((size_t)batch, sizeof(*compressed_lens));
    size_t *restored_lens = calloc((size_t)batch, sizeof(*restored_lens));
    if (!inputs || !compressed || !restored || !input_lens || !output_caps ||
        !compressed_lens || !restored_lens) return 1;

    for (int i = 0; i < batch; i++) {
        uint8_t *input = malloc(GC_BLOCK_SIZE);
        compressed[i] = malloc(slot_bytes);
        if (gpu_tls_alloc_pinned((void **)&restored[i], GC_BLOCK_SIZE) != 0)
            restored[i] = malloc(GC_BLOCK_SIZE);
        if (!input || !compressed[i] || !restored[i]) return 1;
        fill_pattern(input, GC_BLOCK_SIZE, i);
        inputs[i] = input;
        input_lens[i] = GC_BLOCK_SIZE;
        output_caps[i] = slot_bytes;
        restored_lens[i] = GC_BLOCK_SIZE;
    }

    if (gpu_compress_init() != 0) return 1;
    if (gpu_compress_batch(batch, inputs, input_lens, compressed, output_caps,
                           compressed_lens) < 0) return 1;
    if (gpu_decompress_batch(batch, (const uint8_t **)compressed, compressed_lens,
                             restored, restored_lens) != batch) return 1;

    double compress_seconds = 0.0;
    double decompress_seconds = 0.0;
    uint64_t checked_blocks = 0;
    for (long iteration = 0; iteration < iterations; iteration++) {
        uint64_t remaining = total_blocks;
        while (remaining) {
            int n = remaining > (uint64_t)batch ? batch : (int)remaining;
            double start = now_seconds();
            if (gpu_compress_batch(n, inputs, input_lens, compressed, output_caps,
                                   compressed_lens) < 0) return 1;
            compress_seconds += now_seconds() - start;
            for (int i = 0; i < n; i++) {
                if (!compressed_lens[i]) {
                    fprintf(stderr, "unexpected RAW fallback at block %" PRIu64 "\n",
                            checked_blocks + (uint64_t)i);
                    return 1;
                }
            }
            start = now_seconds();
            if (gpu_decompress_batch(n, (const uint8_t **)compressed,
                                     compressed_lens, restored, restored_lens) != n)
                return 1;
            decompress_seconds += now_seconds() - start;
            for (int i = 0; i < n; i++) {
                if (memcmp(inputs[i], restored[i], GC_BLOCK_SIZE) != 0) {
                    fprintf(stderr, "round-trip mismatch at block %" PRIu64 "\n",
                            checked_blocks + (uint64_t)i);
                    return 1;
                }
            }
            checked_blocks += (uint64_t)n;
            remaining -= (uint64_t)n;
        }
    }

    double processed_mib = (double)total_blocks * GC_BLOCK_SIZE * iterations /
                           (1024.0 * 1024.0);
    const char *coalesce = getenv("GPUC_SGLZ_COALESCE");
    if (!coalesce) coalesce = "1";
    printf("coalesce,batch,logical_mib,iterations,checked_blocks,compress_mib_s,decompress_mib_s,status\n");
    printf("%s,%d,%ld,%ld,%" PRIu64 ",%.3f,%.3f,PASS\n", coalesce, batch,
           logical_mib, iterations, checked_blocks,
           processed_mib / compress_seconds, processed_mib / decompress_seconds);
    gpu_compress_fini();
    return 0;
}
