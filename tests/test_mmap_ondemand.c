/*
 * mmap correctness/latency test.
 *
 * The input must use this deterministic page pattern:
 * every 4096-byte page is filled with page_value(page_index).
 * This deliberately avoids all-zero data, which cannot detect reads from
 * anonymous pages that have not been populated yet.
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define PAGE_BYTES 4096U

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint8_t page_value(size_t page_index) {
    return (uint8_t)(((page_index * 131U + 17U) % 251U) + 1U);
}

struct scan_ctx {
    const uint8_t *addr;
    size_t file_size;
    size_t pages;
    size_t thread_id;
    size_t threads;
    size_t mismatches;
    uint64_t checksum;
};

static void *scan_pages(void *arg) {
    struct scan_ctx *ctx = (struct scan_ctx *)arg;
    for (size_t page = ctx->thread_id; page < ctx->pages;
         page += ctx->threads) {
        size_t start = page * PAGE_BYTES;
        size_t end = start + PAGE_BYTES - 1U;
        if (end >= ctx->file_size) end = ctx->file_size - 1U;
        size_t middle = start + (end - start) / 2U;
        uint8_t expected = page_value(page);
        size_t offsets[3] = {start, middle, end};
        for (size_t i = 0; i < 3; i++) {
            uint8_t actual = ctx->addr[offsets[i]];
            ctx->checksum += actual;
            if (actual != expected) ctx->mismatches++;
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <page-pattern-file>\n", argv[0]);
        return 2;
    }

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) {
        perror("fstat");
        close(fd);
        return 1;
    }
    size_t file_size = (size_t)st.st_size;

    double mmap_start = now_sec();
    uint8_t *addr = mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    double mmap_end = now_sec();
    if (addr == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    size_t pages = (file_size + PAGE_BYTES - 1U) / PAGE_BYTES;
    size_t probe_page = pages > 2 ? (pages * 7U / 11U) : 0;
    double first_start = now_sec();
    uint8_t first_actual = addr[probe_page * PAGE_BYTES];
    double first_end = now_sec();
    if (first_actual != page_value(probe_page)) {
        fprintf(stderr, "first random fault mismatch: page=%zu\n", probe_page);
        return 1;
    }

    /* Access every page immediately, optionally from concurrent threads. */
    double scan_start = now_sec();
    size_t mismatches = 0;
    uint64_t checksum = 0;
    size_t threads = 1;
    const char *threads_env = getenv("GPUC_MMAP_THREADS");
    if (threads_env) threads = strtoul(threads_env, NULL, 10);
    if (threads < 1) threads = 1;
    if (threads > 32) threads = 32;
    pthread_t *tids = calloc(threads, sizeof(*tids));
    struct scan_ctx *ctxs = calloc(threads, sizeof(*ctxs));
    if (!tids || !ctxs) return 1;
    for (size_t i = 0; i < threads; i++) {
        ctxs[i] = (struct scan_ctx){
            .addr=addr, .file_size=file_size, .pages=pages,
            .thread_id=i, .threads=threads
        };
        if (pthread_create(&tids[i], NULL, scan_pages, &ctxs[i]) != 0)
            return 1;
    }
    for (size_t i = 0; i < threads; i++) {
        pthread_join(tids[i], NULL);
        mismatches += ctxs[i].mismatches;
        checksum += ctxs[i].checksum;
    }
    free(tids);
    free(ctxs);
    double scan_end = now_sec();

    if (munmap(addr, file_size) != 0) {
        perror("munmap");
        close(fd);
        return 1;
    }
    close(fd);

    printf("size_bytes=%zu mmap_ms=%.3f first_fault_us=%.3f scan_ms=%.3f "
           "pages=%zu threads=%zu checksum=%llu mismatches=%zu\n",
           file_size,
           (mmap_end - mmap_start) * 1000.0,
           (first_end - first_start) * 1000000.0,
           (scan_end - scan_start) * 1000.0,
           pages,
           threads,
           (unsigned long long)checksum,
           mismatches);

    if (mismatches != 0) {
        fprintf(stderr, "mmap scan mismatches=%zu\n", mismatches);
        return 1;
    }
    return 0;
}
