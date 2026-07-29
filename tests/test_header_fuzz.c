#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    DIR *dir = opendir(argv[1]);
    if (!dir) {
        perror("opendir");
        return 1;
    }
    unsigned long tested = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        if (strcmp(entry->d_name, "test_header_fuzz") == 0) continue;
        char path[4096];
        int n = snprintf(path, sizeof(path), "%s/%s", argv[1], entry->d_name);
        if (n < 0 || (size_t)n >= sizeof(path)) {
            closedir(dir);
            return 1;
        }
        errno = 0;
        int fd = open(path, O_RDONLY | O_CLOEXEC);
        if (fd >= 0) {
            unsigned char buf[256];
            ssize_t ignored_read = read(fd, buf, sizeof(buf));
            (void)ignored_read;
            close(fd);
        } else if (errno != EINVAL && errno != EIO && errno != ENOMEM &&
                   errno != EOVERFLOW) {
            fprintf(stderr, "unexpected errno=%d (%s) for %s\n",
                    errno, strerror(errno), path);
            closedir(dir);
            return 1;
        }
        tested++;
    }
    closedir(dir);
    if (tested < 2000) {
        fprintf(stderr, "too few fuzz cases: %lu\n", tested);
        return 1;
    }
    printf("PASS: %lu deterministic malformed-format cases opened without crash\n",
           tested);
    return 0;
}
