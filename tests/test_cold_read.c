#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    size_t expected = strtoull(argv[2], NULL, 10);
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    int advice = posix_fadvise(fd, 0, 0, POSIX_FADV_DONTNEED);
    if (advice != 0) { errno = advice; perror("posix_fadvise"); return 1; }
    if (lseek(fd, 0, SEEK_SET) != 0) { perror("lseek"); return 1; }
    uint8_t *buf = NULL;
    if (posix_memalign((void **)&buf, 4096, 1 << 20) != 0) return 1;
    uint64_t checksum = 0;
    size_t total = 0;
    double begin = now_sec();
    while (total < expected) {
        size_t want = expected-total < (1u<<20) ? expected-total : (1u<<20);
        ssize_t n = read(fd, buf, want);
        if (n <= 0) { perror("read"); return 1; }
        for (ssize_t i = 0; i < n; i += 4096) checksum += buf[i];
        total += (size_t)n;
    }
    double elapsed = now_sec() - begin;
    close(fd);
    free(buf);
    printf("%.6f,%.3f,%zu,%llu\n", elapsed,
           total / 1048576.0 / elapsed, total,
           (unsigned long long)checksum);
    return 0;
}
