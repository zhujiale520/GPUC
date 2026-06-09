/*
 * test_hook.c - LD_PRELOAD hook 集成测试程序
 *
 * 用法：
 *   test_hook write <path> <size>
 *   test_hook read <path> <size>
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>

static int do_write(const char *path, int size) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open for write");
        return -1;
    }

    uint8_t *buf = (uint8_t *)malloc(size);
    for (int i = 0; i < size; i++) {
        buf[i] = (uint8_t)(i % 256);
    }

    ssize_t nw = write(fd, buf, size);
    if (nw != size) {
        fprintf(stderr, "write failed: %zd\n", nw);
        free(buf);
        close(fd);
        return -1;
    }

    free(buf);
    close(fd);
    printf("[test_hook] Wrote %d bytes to %s\n", size, path);
    return 0;
}

/* 生成混合可压缩性数据：前半为重复数据（可压缩），后半为随机数据（不可压缩） */
static int do_write_mixed(const char *path, int size) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        perror("open for write");
        return -1;
    }

    uint8_t *buf = (uint8_t *)malloc(size);
    int half = size / 2;

    /* Block 0: 重复数据（可压缩） */
    for (int i = 0; i < half; i++) {
        buf[i] = (uint8_t)(i % 7);
    }

    /* Block 1: 伪随机数据（不可压缩） */
    unsigned int seed = 0x12345678;
    for (int i = half; i < size; i++) {
        seed = seed * 1103515245 + 12345;
        buf[i] = (uint8_t)(seed >> 16);
    }

    ssize_t nw = write(fd, buf, size);
    if (nw != size) {
        fprintf(stderr, "write failed: %zd\n", nw);
        free(buf);
        close(fd);
        return -1;
    }

    free(buf);
    close(fd);
    printf("[test_hook] Wrote %d bytes (mixed compressible) to %s\n", size, path);
    return 0;
}

static int do_read_mixed(const char *path, int size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror("open for read");
        return -1;
    }

    uint8_t *buf = (uint8_t *)malloc(size);
    ssize_t nr = read(fd, buf, size);
    if (nr != size) {
        fprintf(stderr, "read failed: %zd (expected %d)\n", nr, size);
        free(buf);
        close(fd);
        return -1;
    }

    int half = size / 2;
    int ok = 1;

    /* 验证 Block 0 */
    for (int i = 0; i < half; i++) {
        if (buf[i] != (uint8_t)(i % 7)) {
            fprintf(stderr, "[test_hook] Block0 mismatch at byte %d: got %d, expected %d\n",
                    i, buf[i], i % 7);
            ok = 0;
            break;
        }
    }

    /* 验证 Block 1 */
    if (ok) {
        unsigned int seed = 0x12345678;
        uint8_t expected;
        for (int i = half; i < size; i++) {
            seed = seed * 1103515245 + 12345;
            expected = (uint8_t)(seed >> 16);
            if (buf[i] != expected) {
                fprintf(stderr, "[test_hook] Block1 mismatch at byte %d: got %d, expected %d\n",
                        i, buf[i], expected);
                ok = 0;
                break;
            }
        }
    }

    if (ok) {
        printf("[test_hook] Read %zd bytes (mixed), data verified OK\n", nr);
    }

    free(buf);
    close(fd);
    return ok ? 0 : -1;
}

static int do_read(const char *path, int size) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror("open for read");
        return -1;
    }

    uint8_t *buf = (uint8_t *)malloc(size);
    ssize_t nr = read(fd, buf, size);
    if (nr != size) {
        fprintf(stderr, "read failed: %zd (expected %d)\n", nr, size);
        free(buf);
        close(fd);
        return -1;
    }

    int ok = 1;
    for (int i = 0; i < size; i++) {
        if (buf[i] != (uint8_t)(i % 256)) {
            fprintf(stderr, "[test_hook] Data mismatch at byte %d: got %d, expected %d\n",
                    i, buf[i], i % 256);
            ok = 0;
            break;
        }
    }

    if (ok) {
        printf("[test_hook] Read %zd bytes, data verified OK\n", nr);
    }

    free(buf);
    close(fd);
    return ok ? 0 : -1;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "Usage: %s write|read <path> <size>\n", argv[0]);
        return 1;
    }

    const char *mode = argv[1];
    const char *path = argv[2];
    int size = atoi(argv[3]);

    if (size <= 0) {
        fprintf(stderr, "Invalid size: %s\n", argv[3]);
        return 1;
    }

    if (strcmp(mode, "write") == 0) {
        return do_write(path, size);
    } else if (strcmp(mode, "read") == 0) {
        return do_read(path, size);
    } else if (strcmp(mode, "writemixed") == 0) {
        return do_write_mixed(path, size);
    } else if (strcmp(mode, "readmixed") == 0) {
        return do_read_mixed(path, size);
    } else {
        fprintf(stderr, "Unknown mode: %s\n", mode);
        return 1;
    }
}
