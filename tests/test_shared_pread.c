#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define FILE_SIZE (16 * 1024 * 1024)
#define PAGE_SIZE 4096
#define READ_SIZE (128 * 1024)
#define THREADS 4
#define ITERATIONS 64

struct worker_arg {
    int fd;
    int thread_id;
    int failed;
};

static uint8_t expected_byte(size_t absolute_offset) {
    size_t page = absolute_offset / PAGE_SIZE;
    return (uint8_t)(((page * 131 + 17) % 251) + 1);
}

static void *worker_main(void *opaque) {
    struct worker_arg *arg = (struct worker_arg *)opaque;
    uint8_t *buf = NULL;
    if (posix_memalign((void **)&buf, PAGE_SIZE, READ_SIZE) != 0) {
        arg->failed = 1;
        return NULL;
    }

    const size_t blocks = FILE_SIZE / READ_SIZE;
    for (int iteration = 0; iteration < ITERATIONS; iteration++) {
        size_t block = (size_t)(arg->thread_id * 17 + iteration * 13) % blocks;
        off_t offset = (off_t)(block * READ_SIZE);
        ssize_t got = pread(arg->fd, buf, READ_SIZE, offset);
        if (got != READ_SIZE) {
            fprintf(stderr,
                    "thread %d: pread offset=%lld returned %zd errno=%d\n",
                    arg->thread_id, (long long)offset, got, errno);
            arg->failed = 1;
            break;
        }
        for (size_t index = 0; index < READ_SIZE; index++) {
            uint8_t want = expected_byte((size_t)offset + index);
            if (buf[index] != want) {
                fprintf(stderr,
                        "thread %d: mismatch offset=%lld index=%zu "
                        "got=%u want=%u\n",
                        arg->thread_id, (long long)offset, index,
                        (unsigned)buf[index], (unsigned)want);
                arg->failed = 1;
                break;
            }
        }
        if (arg->failed) break;
    }

    free(buf);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s COMPRESSED_FILE\n", argv[0]);
        return 2;
    }

    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    pthread_t threads[THREADS];
    struct worker_arg args[THREADS];
    memset(args, 0, sizeof(args));
    int started = 0;
    for (int index = 0; index < THREADS; index++) {
        args[index].fd = fd;
        args[index].thread_id = index;
        int rc = pthread_create(&threads[index], NULL, worker_main, &args[index]);
        if (rc != 0) {
            errno = rc;
            perror("pthread_create");
            break;
        }
        started++;
    }

    int failed = started != THREADS;
    for (int index = 0; index < started; index++) {
        if (pthread_join(threads[index], NULL) != 0) failed = 1;
        failed |= args[index].failed;
    }
    close(fd);

    if (failed) return 1;
    puts("PASS: four threads shared one fd for concurrent compressed pread");
    return 0;
}
