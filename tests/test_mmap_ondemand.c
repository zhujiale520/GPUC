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

    /*
     * Access every page immediately after mmap returns. In particular this
     * reaches well beyond the old 16 MB preload boundary without sleeping.
     */
    double scan_start = now_sec();
    size_t pages = (file_size + PAGE_BYTES - 1U) / PAGE_BYTES;
    size_t mismatches = 0;
    size_t first_bad_offset = 0;
    uint8_t first_expected = 0;
    uint8_t first_actual = 0;
    volatile uint64_t checksum = 0;

    for (size_t page = 0; page < pages; page++) {
        size_t start = page * PAGE_BYTES;
        size_t end = start + PAGE_BYTES - 1U;
        if (end >= file_size) end = file_size - 1U;
        size_t middle = start + (end - start) / 2U;
        uint8_t expected = page_value(page);
        size_t offsets[3] = {start, middle, end};

        for (size_t i = 0; i < 3; i++) {
            uint8_t actual = addr[offsets[i]];
            checksum += actual;
            if (actual != expected) {
                if (mismatches == 0) {
                    first_bad_offset = offsets[i];
                    first_expected = expected;
                    first_actual = actual;
                }
                mismatches++;
            }
        }
    }
    double scan_end = now_sec();

    if (munmap(addr, file_size) != 0) {
        perror("munmap");
        close(fd);
        return 1;
    }
    close(fd);

    printf("size_bytes=%zu mmap_ms=%.3f scan_ms=%.3f pages=%zu checksum=%llu mismatches=%zu\n",
           file_size,
           (mmap_end - mmap_start) * 1000.0,
           (scan_end - scan_start) * 1000.0,
           pages,
           (unsigned long long)checksum,
           mismatches);

    if (mismatches != 0) {
        fprintf(stderr,
                "first mismatch: offset=%zu expected=0x%02x actual=0x%02x\n",
                first_bad_offset, first_expected, first_actual);
        return 1;
    }
    return 0;
}
