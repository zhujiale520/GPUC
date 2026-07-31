#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}
static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s FILE RUNTIME_S\n", argv[0]);
        return 2;
    }
    double runtime = strtod(argv[2], NULL);
    if (!(runtime > 0.0)) return 2;
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 1; }
    struct stat st;
    if (fstat(fd, &st) != 0) { perror("fstat"); close(fd); return 1; }
    if (st.st_size <= 0) {
        fprintf(stderr, "input file is empty\n"); close(fd); return 1;
    }
    const size_t chunk = 128 * 1024;
    uint8_t *buffer = NULL;
    if (posix_memalign((void **)&buffer, 4096, chunk) != 0) return 1;
    size_t cap = 128, scans = 0;
    double *latencies = malloc(cap * sizeof(*latencies));
    uint64_t final_hash = 0, total_bytes = 0, marker_hits = 0;
    double begin = now_s();
    do {
        uint64_t hash = UINT64_C(1469598103934665603), hits = 0;
        off_t offset = 0;
        double scan_begin = now_s();
        while (offset < st.st_size) {
            size_t want = (size_t)(st.st_size - offset);
            if (want > chunk) want = chunk;
            ssize_t n = pread(fd, buffer, want, offset);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) {
                if (n == 0) fprintf(stderr, "unexpected EOF at %jd\n", (intmax_t)offset);
                else perror("pread");
                free(latencies); free(buffer); close(fd); return 1;
            }
            for (ssize_t i = 0; i < n; ++i) {
                hash ^= buffer[i];
                hash *= UINT64_C(1099511628211);
                if (i + 4 < n && (buffer[i] == 'e' || buffer[i] == 'E') &&
                    (buffer[i+1] == 'r' || buffer[i+1] == 'R') &&
                    (buffer[i+2] == 'r' || buffer[i+2] == 'R') &&
                    (buffer[i+3] == 'o' || buffer[i+3] == 'O') &&
                    (buffer[i+4] == 'r' || buffer[i+4] == 'R')) hits++;
            }
            offset += n;
        }
        if (scans == cap) {
            cap *= 2;
            double *next = realloc(latencies, cap * sizeof(*next));
            if (!next) { free(latencies); free(buffer); close(fd); return 1; }
            latencies = next;
        }
        latencies[scans++] = now_s() - scan_begin;
        final_hash = hash; marker_hits = hits;
        total_bytes += (uint64_t)st.st_size;
    } while (now_s() - begin < runtime);
    double elapsed = now_s() - begin;
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    qsort(latencies, scans, sizeof(*latencies), cmp_double);
    size_t p99 = (size_t)ceil((double)scans * 0.99) - 1;
    double cpu = usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 +
                 usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6;
    printf("%.6f,%" PRIu64 ",%zu,%.6f,%.6f,%.6f,%.6f,%" PRIu64
           ",%" PRIu64 ",%" PRIu64 ",%ld\n",
           elapsed, total_bytes, scans, total_bytes / elapsed / 1048576.0,
           scans / elapsed, latencies[p99] * 1000.0, cpu / elapsed,
           final_hash, marker_hits, (uint64_t)st.st_size, usage.ru_maxrss);
    free(latencies); free(buffer); close(fd);
    return 0;
}
