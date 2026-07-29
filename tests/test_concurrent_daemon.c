#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define PAGE 4096

static uint8_t page_value(size_t page) {
    return (uint8_t)(1u + (page * 37u) % 251u);
}

static void die(const char *s) { perror(s); exit(1); }

static int create_file(const char *path, size_t bytes) {
    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0640);
    if (fd < 0) die("open create");
    uint8_t page[PAGE];
    for (size_t p = 0; p < bytes / PAGE; p++) {
        memset(page, page_value(p), sizeof(page));
        if (write(fd, page, sizeof(page)) != sizeof(page)) die("write create");
    }
    if (fsync(fd) != 0) die("fsync create");
    close(fd);
    return 0;
}

static int verify_fd(int fd, size_t bytes) {
    uint8_t buf[1 << 20];
    size_t off = 0;
    while (off < bytes) {
        size_t want = bytes - off < sizeof(buf) ? bytes - off : sizeof(buf);
        ssize_t n = read(fd, buf, want);
        if (n != (ssize_t)want) return -1;
        for (size_t i = 0; i < want; i++) {
            if (buf[i] != page_value((off + i) / PAGE)) return -1;
        }
        off += want;
    }
    return 0;
}

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int read_loop(const char *path, size_t bytes, double seconds, int reopen) {
    int fd = -1, loops = 0;
    double end = now_sec() + seconds;
    if (!reopen) {
        fd = open(path, O_RDONLY);
        if (fd < 0) die("open held");
    }
    while (now_sec() < end) {
        if (reopen) {
            fd = open(path, O_RDONLY);
            if (fd < 0) die("open reopen");
        } else if (lseek(fd, 0, SEEK_SET) != 0) {
            die("lseek held");
        }
        if (verify_fd(fd, bytes) != 0) {
            fprintf(stderr, "FAIL: concurrent content mismatch reopen=%d loop=%d errno=%d\n",
                    reopen, loops, errno);
            return 1;
        }
        if (reopen) close(fd);
        loops++;
    }
    if (!reopen) close(fd);
    printf("PASS: concurrent reader reopen=%d loops=%d\n", reopen, loops);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    const char *mode = argv[1], *path = argv[2];
    size_t mib = strtoull(argv[3], NULL, 10);
    size_t bytes = mib * 1024u * 1024u;
    if (strcmp(mode, "create") == 0) return create_file(path, bytes);
    if (argc != 5) return 2;
    double seconds = atof(argv[4]);
    if (strcmp(mode, "held") == 0) return read_loop(path, bytes, seconds, 0);
    if (strcmp(mode, "reopen") == 0) return read_loop(path, bytes, seconds, 1);
    return 2;
}
