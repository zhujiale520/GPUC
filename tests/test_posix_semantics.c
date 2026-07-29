#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <sys/xattr.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void fail(const char *what) {
    perror(what);
    exit(1);
}

static void expect_bytes(int fd, const char *want, size_t len) {
    char buf[64] = {0};
    ssize_t n = pread(fd, buf, len, 0);
    if (n != (ssize_t)len || memcmp(buf, want, len) != 0) {
        fprintf(stderr, "FAIL: content mismatch: got %zd bytes \"%.*s\", want \"%.*s\"\n",
                n, n > 0 ? (int)n : 0, buf, (int)len, want);
        exit(1);
    }
}

static int test_raw(const char *path) {
    unlink(path);
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0600);
    if (fd < 0) fail("open raw");

    struct iovec iov[2] = {
        {.iov_base = (void *)"abc", .iov_len = 3},
        {.iov_base = (void *)"def", .iov_len = 3},
    };
    if (writev(fd, iov, 2) != 6) fail("writev");
    if (pwrite(fd, "XY", 2, 2) != 2) fail("pwrite");
    expect_bytes(fd, "abXYef", 6);

    if (ftruncate(fd, 4) != 0) fail("ftruncate");
    expect_bytes(fd, "abXY", 4);
    if (ftruncate64(fd, 8192) != 0) fail("ftruncate64");
    int alloc_rc = posix_fallocate64(fd, 0, 16384);
    if (alloc_rc != 0) {
        errno = alloc_rc;
        fail("posix_fallocate64");
    }
    if (fallocate64(fd, 0, 0, 16384) != 0) fail("fallocate64");
    for (int i = 0; i < 512; i++) {
        off64_t offset = (off64_t)((i * 7919) % (16384 - 4));
        if (pwrite(fd, "RAND", 4, offset) != 4)
            fail("repeated random pwrite");
    }
    if (pwrite(fd, "TAIL", 4, 8188) != 4) fail("pwrite tail after ftruncate64");
    char tail[4] = {0};
    if (pread(fd, tail, sizeof(tail), 8188) != 4 ||
        memcmp(tail, "TAIL", sizeof(tail)) != 0) {
        fprintf(stderr, "FAIL: ftruncate64 logical tail is not readable\n");
        return 1;
    }
    if (pwrite(fd, "END!", 4, 16380) != 4) fail("pwrite logical end");
    struct stat logical_st;
    if (fstat(fd, &logical_st) != 0) fail("fstat logical size");
    if (logical_st.st_size != 16384) {
        fprintf(stderr, "FAIL: tracked logical size=%lld, expected 16384\n",
                (long long)logical_st.st_size);
        return 1;
    }
    if (lseek(fd, 16380, SEEK_SET) != 16380) fail("lseek logical end");
    ssize_t tail_n = read(fd, tail, sizeof(tail));
    if (tail_n != 4 || memcmp(tail, "END!", sizeof(tail)) != 0) {
        fprintf(stderr,
                "FAIL: repeated pwrite corrupted tracked logical size "
                "(read=%zd bytes=%02x%02x%02x%02x)\n",
                tail_n, (unsigned char)tail[0], (unsigned char)tail[1],
                (unsigned char)tail[2], (unsigned char)tail[3]);
        return 1;
    }
    if (pwrite(fd, "abXY", 4, 0) != 4) fail("restore prefix");
    if (ftruncate64(fd, 4) != 0) fail("ftruncate64 shrink");
    close(fd);

    fd = open(path, O_WRONLY | O_APPEND);
    if (fd < 0) fail("open append");
    if (write(fd, "Z", 1) != 1) fail("append write");
    close(fd);

    fd = open(path, O_RDONLY);
    if (fd < 0) fail("reopen");
    expect_bytes(fd, "abXYZ", 5);

    if (lseek(fd, 0, SEEK_SET) != 0) fail("lseek");
    int fd2 = dup(fd);
    if (fd2 < 0) fail("dup");
    char a = 0, b = 0;
    if (read(fd, &a, 1) != 1 || read(fd2, &b, 1) != 1) fail("dup read");
    if (a != 'a' || b != 'b') {
        fprintf(stderr, "FAIL: dup offsets are not shared: '%c' then '%c'\n", a, b);
        return 1;
    }
    close(fd2);
    close(fd);

    void *direct_buf = NULL;
    if (posix_memalign(&direct_buf, 4096, 4096) != 0) fail("posix_memalign");
    fd = open(path, O_RDONLY | O_DIRECT);
    if (fd < 0) fail("open managed O_DIRECT");
    int effective = fcntl(fd, F_GETFL);
    if (effective < 0 || (effective & O_DIRECT)) {
        fprintf(stderr, "FAIL: managed O_DIRECT was not explicitly normalized\n");
        return 1;
    }
    if (read(fd, direct_buf, 4096) != 5 || memcmp(direct_buf, "abXYZ", 5) != 0) {
        fprintf(stderr, "FAIL: managed O_DIRECT logical read\n");
        return 1;
    }
    close(fd);
    free(direct_buf);
    puts("PASS: RAW writev/pwrite/O_APPEND/truncate/fallocate/dup semantics");
    return 0;
}

static int expect_erofs(const char *name, int rc) {
    if (rc != -1 || errno != EROFS) {
        fprintf(stderr, "FAIL: %s returned %d errno=%d; expected -1/EROFS\n",
                name, rc, errno);
        return 1;
    }
    return 0;
}

static int test_compressed(const char *path) {
    int fd = open(path, O_RDWR);
    if (fd < 0) fail("open compressed");
    int failed = 0;
    errno = 0;
    failed |= expect_erofs("write", (int)write(fd, "x", 1));
    errno = 0;
    failed |= expect_erofs("pwrite", (int)pwrite(fd, "x", 1, 0));
    struct iovec iov = {.iov_base = (void *)"x", .iov_len = 1};
    errno = 0;
    failed |= expect_erofs("writev", (int)writev(fd, &iov, 1));
    errno = 0;
    failed |= expect_erofs("ftruncate", ftruncate(fd, 1));
    errno = 0;
    failed |= expect_erofs("ftruncate64", ftruncate64(fd, 1));
    errno = 0;
    failed |= expect_erofs("fallocate64", fallocate64(fd, 0, 0, 4096));
    int alloc_rc = posix_fallocate64(fd, 0, 4096);
    if (alloc_rc != EROFS) {
        fprintf(stderr, "FAIL: posix_fallocate64 returned %d; expected EROFS\n",
                alloc_rc);
        failed = 1;
    }
    close(fd);
    if (failed) return 1;
    puts("PASS: COMPRESSED mutation is rejected with EROFS");
    return 0;
}

static int test_whitelist_rename(const char *path) {
    char target[4096];
    if (snprintf(target, sizeof(target), "%s.db", path) >= (int)sizeof(target))
        return 1;
    unlink(path);
    unlink(target);
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0640);
    if (fd < 0) fail("open rename source");
    const char payload[] = "rename-metadata";
    if (write(fd, payload, sizeof(payload) - 1) != (ssize_t)(sizeof(payload) - 1))
        fail("write rename source");
    if (fchmod(fd, 0640) != 0) fail("fchmod rename source");
    const char xvalue[] = "gpuc-xattr";
    if (fsetxattr(fd, "user.gpuc_test", xvalue, sizeof(xvalue) - 1, 0) != 0)
        fail("fsetxattr rename source");
    struct timespec times[2] = {
        {.tv_sec = 1700000000, .tv_nsec = 123456789},
        {.tv_sec = 1700000000, .tv_nsec = 123456789},
    };
    if (futimens(fd, times) != 0) fail("futimens rename source");
    close(fd);

    if (rename(path, target) != 0) fail("rename to whitelist");
    if (access(path, F_OK) == 0) {
        fprintf(stderr, "FAIL: rename source still exists\n");
        return 1;
    }
    fd = open(target, O_RDONLY);
    if (fd < 0) fail("open rename target");
    char got[sizeof(payload)] = {0};
    if (read(fd, got, sizeof(payload) - 1) != (ssize_t)(sizeof(payload) - 1) ||
        memcmp(got, payload, sizeof(payload) - 1) != 0) {
        fprintf(stderr, "FAIL: whitelist target content/header stripping\n");
        return 1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) fail("fstat rename target");
    if ((st.st_mode & 0777) != 0640 ||
        st.st_mtim.tv_sec != times[1].tv_sec ||
        st.st_mtim.tv_nsec != times[1].tv_nsec) {
        fprintf(stderr, "FAIL: whitelist target mode/mtime not preserved\n");
        return 1;
    }
    char xgot[32] = {0};
    ssize_t xn = fgetxattr(fd, "user.gpuc_test", xgot, sizeof(xgot));
    if (xn != (ssize_t)(sizeof(xvalue) - 1) ||
        memcmp(xgot, xvalue, sizeof(xvalue) - 1) != 0) {
        fprintf(stderr, "FAIL: whitelist target xattr not preserved\n");
        return 1;
    }
    close(fd);
    puts("PASS: whitelist rename is atomic and preserves mode/mtime/xattr");
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s raw|compressed|rename PATH\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "raw") == 0) return test_raw(argv[2]);
    if (strcmp(argv[1], "compressed") == 0) return test_compressed(argv[2]);
    if (strcmp(argv[1], "rename") == 0) return test_whitelist_rename(argv[2]);
    return 2;
}
