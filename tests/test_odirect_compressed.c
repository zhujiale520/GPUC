#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s FILE\n", argv[0]);
        return 2;
    }
    int fd = open(argv[1], O_RDONLY | O_DIRECT);
    if (fd < 0) {
        perror("open O_DIRECT");
        return 1;
    }
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || !(flags & O_DIRECT)) {
        fprintf(stderr, "FAIL: O_DIRECT was cleared for aligned compressed file\n");
        close(fd);
        return 1;
    }
    void *buffer = NULL;
    if (posix_memalign(&buffer, 4096, 128 * 1024) != 0) {
        close(fd);
        return 1;
    }
    ssize_t n = read(fd, buffer, 128 * 1024);
    if (n != 128 * 1024) {
        perror("read O_DIRECT");
        free(buffer);
        close(fd);
        return 1;
    }
    const uint8_t *p = (const uint8_t *)buffer;
    for (size_t i = 0; i < (size_t)n; i++) {
        if (p[i] != 0) {
            fprintf(stderr, "FAIL: logical data mismatch at %zu\n", i);
            free(buffer);
            close(fd);
            return 1;
        }
    }
    puts("PASS: aligned compressed file retained O_DIRECT and read correctly");
    free(buffer);
    close(fd);
    return 0;
}
