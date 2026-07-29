#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <pthread.h>

#include "gpu_compress_api.h"

#define BLOCK_SIZE (128u * 1024u)
#define NUM_BLOCKS 128
#define REPEATS 5
#define OUT_CAP (BLOCK_SIZE + BLOCK_SIZE / 255u + 32u)
#define CONCURRENT_CALLERS 4

struct concurrent_job {
    const uint8_t **in;
    const size_t *in_lens;
    const size_t *out_lens;
    const uint8_t *expected;
    uint8_t *decoded;
    uint8_t *out[NUM_BLOCKS];
    int result;
};

static void *run_concurrent_gpu(void *arg) {
    struct concurrent_job *job = (struct concurrent_job *)arg;
    for (int i = 0; i < NUM_BLOCKS; i++)
        job->out[i] = job->decoded + (size_t)i * BLOCK_SIZE;
    int rc = gpu_lz4_decompress_batch(
        NUM_BLOCKS, job->in, job->in_lens, job->out, job->out_lens);
    job->result = rc == NUM_BLOCKS &&
                  memcmp(job->expected, job->decoded,
                         (size_t)NUM_BLOCKS * BLOCK_SIZE) == 0 ? 0 : -1;
    return NULL;
}

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void fill_input(uint8_t *p, size_t n) {
    for (size_t page = 0; page < n / 4096; page++) {
        uint8_t v = (uint8_t)(1u + (page * 37u) % 251u);
        memset(p + page * 4096, v, 4096);
    }
}

int main(void) {
    const size_t total = (size_t)NUM_BLOCKS * BLOCK_SIZE;
    uint8_t *src = NULL;
    uint8_t *decoded = NULL;
    int pinned = gpu_lz4_host_alloc((void **)&src, total) == 0 &&
                 gpu_lz4_host_alloc((void **)&decoded, total) == 0;
    if (!pinned) {
        if (src) gpu_lz4_host_free(src);
        if (decoded) gpu_lz4_host_free(decoded);
        src = aligned_alloc(4096, total);
        decoded = aligned_alloc(4096, total);
    }
    uint8_t **comp = calloc(NUM_BLOCKS, sizeof(*comp));
    const uint8_t **in = calloc(NUM_BLOCKS, sizeof(*in));
    uint8_t **out = calloc(NUM_BLOCKS, sizeof(*out));
    size_t *in_lens = calloc(NUM_BLOCKS, sizeof(*in_lens));
    size_t *out_lens = calloc(NUM_BLOCKS, sizeof(*out_lens));
    size_t *caps = calloc(NUM_BLOCKS, sizeof(*caps));
    double cpu[REPEATS], gpu[REPEATS];
    if (!src || !decoded || !comp || !in || !out || !in_lens || !out_lens || !caps)
        return 1;

    fill_input(src, total);
    for (int i = 0; i < NUM_BLOCKS; i++) {
        if (pinned && gpu_lz4_host_alloc((void **)&comp[i], OUT_CAP) != 0)
            return 1;
        if (!pinned) comp[i] = aligned_alloc(4096, OUT_CAP);
        if (!comp[i]) return 1;
        in[i] = src + (size_t)i * BLOCK_SIZE;
        out[i] = comp[i];
        in_lens[i] = BLOCK_SIZE;
        caps[i] = OUT_CAP;
    }
    if (cpu_lz4_compress_batch(NUM_BLOCKS, in, in_lens, comp, caps, out_lens) < 0) {
        fprintf(stderr, "CPU LZ4 preparation failed\n");
        return 1;
    }
    size_t stored = 0;
    for (int i = 0; i < NUM_BLOCKS; i++) {
        in[i] = comp[i];
        in_lens[i] = out_lens[i];
        out[i] = decoded + (size_t)i * BLOCK_SIZE;
        out_lens[i] = BLOCK_SIZE;
        stored += in_lens[i];
    }

    if (gpu_lz4_init() != 0) {
        fprintf(stderr, "GPU LZ4 init failed\n");
        return 1;
    }
    /* Warm both full paths outside timed repetitions (allocator/driver/page faults). */
    if (cpu_lz4_decompress_batch(NUM_BLOCKS, in, in_lens, out, out_lens) < 0 ||
        gpu_lz4_decompress_batch(NUM_BLOCKS, in, in_lens, out, out_lens) < 0)
        return 1;

    puts("backend,repeat,mib_s");
    for (int r = 0; r < REPEATS; r++) {
        memset(decoded, 0, total);
        double t0 = now_sec();
        if (cpu_lz4_decompress_batch(NUM_BLOCKS, in, in_lens, out, out_lens) < 0) return 1;
        double elapsed = now_sec() - t0;
        cpu[r] = (total / 1048576.0) / elapsed;
        if (memcmp(src, decoded, total) != 0) {
            fprintf(stderr, "CPU LZ4 mismatch\n");
            return 1;
        }
        printf("cpu_liblz4,%d,%.3f\n", r + 1, cpu[r]);

        memset(decoded, 0, total);
        t0 = now_sec();
        if (gpu_lz4_decompress_batch(NUM_BLOCKS, in, in_lens, out, out_lens) < 0) return 1;
        elapsed = now_sec() - t0;
        gpu[r] = (total / 1048576.0) / elapsed;
        if (memcmp(src, decoded, total) != 0) {
            fprintf(stderr, "GPU nvCOMP LZ4 mismatch\n");
            return 1;
        }
        printf("gpu_nvcomp_lz4,%d,%.3f\n", r + 1, gpu[r]);
    }

    qsort(cpu, REPEATS, sizeof(double), cmp_double);
    qsort(gpu, REPEATS, sizeof(double), cmp_double);
    fprintf(stderr,
            "logical_bytes=%zu stored_bytes=%zu ratio=%.4f "
            "cpu_median_mib_s=%.3f gpu_median_mib_s=%.3f gpu_over_cpu=%.3f\n",
            total, stored, (double)stored / total,
            cpu[REPEATS / 2], gpu[REPEATS / 2],
            gpu[REPEATS / 2] / cpu[REPEATS / 2]);

    pthread_t callers[CONCURRENT_CALLERS];
    struct concurrent_job jobs[CONCURRENT_CALLERS];
    memset(jobs, 0, sizeof(jobs));
    for (int t = 0; t < CONCURRENT_CALLERS; t++) {
        jobs[t].in = in;
        jobs[t].in_lens = in_lens;
        jobs[t].out_lens = out_lens;
        jobs[t].expected = src;
        jobs[t].decoded = aligned_alloc(4096, total);
        if (!jobs[t].decoded ||
            pthread_create(&callers[t], NULL, run_concurrent_gpu, &jobs[t]) != 0)
            return 1;
    }
    for (int t = 0; t < CONCURRENT_CALLERS; t++) {
        pthread_join(callers[t], NULL);
        if (jobs[t].result != 0) {
            fprintf(stderr, "concurrent GPU LZ4 mismatch at caller %d\n", t);
            return 1;
        }
        free(jobs[t].decoded);
    }
    fprintf(stderr, "concurrent_callers=%d status=pass\n", CONCURRENT_CALLERS);

    gpu_lz4_fini();
    for (int i = 0; i < NUM_BLOCKS; i++) {
        if (pinned) gpu_lz4_host_free(comp[i]);
        else free(comp[i]);
    }
    if (pinned) {
        gpu_lz4_host_free(src);
        gpu_lz4_host_free(decoded);
    } else {
        free(src);
        free(decoded);
    }
    free(comp);
    free(in);
    free(out);
    free(in_lens);
    free(out_lens);
    free(caps);
    return 0;
}
