#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    for (int i = 1; i < argc; i++) {
        int modes[] = {O_RDONLY, O_WRONLY};
        for (unsigned m = 0; m < sizeof(modes)/sizeof(modes[0]); m++) {
            errno = 0;
            int fd = open(argv[i], modes[m]);
            if (fd >= 0) {
                fprintf(stderr, "FAIL: corrupt GPUC opened: %s flags=%d\n",
                        argv[i], modes[m]);
                close(fd);
                return 1;
            }
            if (errno != EINVAL) {
                fprintf(stderr, "FAIL: %s errno=%d (%s), expected EINVAL\n",
                        argv[i], errno, strerror(errno));
                return 1;
            }
        }
    }
    puts("PASS: corrupt GPUC headers/block tables rejected");
    return 0;
}
