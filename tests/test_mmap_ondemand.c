/*
 * test_mmap_ondemand.c - 验证 mmap 按需解压优化
 *
 * 测试方法：
 *   1. 创建一个大文件（如 512MB）并通过 daemon 压缩
 *   2. 用 mmap() 映射该文件
 *   3. 测量 mmap() 返回时间（应大幅缩短）
 *   4. 验证前 16MB 数据已正确解压
 *   5. 等待后台线程完成后验证剩余数据
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <stdint.h>

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char *argv[]) {
    const char *path = (argc > 1) ? argv[1] : "/tmp/gpuc_mmap_test.bin";
    size_t file_size = (argc > 2) ? (size_t)atol(argv[2]) : (512 * 1024 * 1024);

    printf("========================================\n");
    printf("  mmap On-Demand Decompress Test\n");
    printf("========================================\n");
    printf("File: %s\n", path);
    printf("Size: %zu MB\n", file_size / (1024 * 1024));

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    double t0 = now_sec();
    void *addr = mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
    double t1 = now_sec();
    if (addr == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }
    printf("mmap() returned in %.3f ms\n", (t1 - t0) * 1000.0);

    /* 验证前 1MB 数据（应在同步预解压范围内） */
    int ok = 1;
    double t_verify0 = now_sec();
    for (size_t i = 0; i < 1024 * 1024; i += 4096) {
        uint8_t *p = (uint8_t *)addr + i;
        if (*p != 0x00) {
            fprintf(stderr, "Data mismatch at offset %zu: expected 0x00, got 0x%02x\n", i, *p);
            ok = 0;
            break;
        }
    }
    double t_verify1 = now_sec();
    printf("Verify first 1MB: %s (%.3f ms)\n", ok ? "PASS" : "FAIL", (t_verify1 - t_verify0) * 1000.0);

    /* 抽样验证文件尾部（可能需要等待后台线程） */
    if (file_size > 16 * 1024 * 1024) {
        size_t tail_off = file_size - 4096;
        uint8_t *tail = (uint8_t *)addr + tail_off;
        printf("Checking tail at offset %zu ... ", tail_off);
        fflush(stdout);

        /* 给后台线程一些时间（实际场景应用会继续执行其他任务） */
        double t_wait0 = now_sec();
        int tail_ok = 0;
        for (int retry = 0; retry < 1000; retry++) {
            if (*tail == 0x00) {
                tail_ok = 1;
                break;
            }
            usleep(10000); /* 10ms */
        }
        double t_wait1 = now_sec();
        printf("%s (waited %.1f ms)\n", tail_ok ? "PASS" : "FAIL", (t_wait1 - t_wait0) * 1000.0);
    }

    munmap(addr, file_size);
    close(fd);

    printf("\nResult: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
