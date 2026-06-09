#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "gpu_compress_api.h"

int main() {
    if (gpu_compress_init() != 0) {
        fprintf(stderr, "GPU init failed\n");
        return 1;
    }

    FILE *f = fopen("/tmp/block0_slot.bin", "rb");
    if (!f) {
        perror("fopen");
        return 1;
    }

    uint8_t *slot_buf = (uint8_t *)malloc(GC_NCHUNKS * GC_SLOT_SIZE);
    fread(slot_buf, 1, GC_NCHUNKS * GC_SLOT_SIZE, f);
    fclose(f);

    uint8_t *decomp = (uint8_t *)malloc(GC_BLOCK_SIZE);
    
    printf("Calling gpu_decompress_128k...\n");
    int ret = gpu_decompress_128k(slot_buf, GC_NCHUNKS * GC_SLOT_SIZE, decomp, GC_BLOCK_SIZE);
    printf("Return: %d\n", ret);

    printf("First 32 bytes of decompressed data:\n");
    for (int i = 0; i < 32; i++) {
        printf("%02x ", decomp[i]);
        if ((i + 1) % 16 == 0) printf("\n");
    }

    int ok = 1;
    for (int i = 0; i < GC_BLOCK_SIZE; i++) {
        if (decomp[i] != (uint8_t)(i % 256)) {
            printf("Mismatch at byte %d: got %d, expected %d\n", i, decomp[i], i % 256);
            ok = 0;
            break;
        }
    }

    if (ok) printf("All %d bytes match!\n", GC_BLOCK_SIZE);

    free(slot_buf);
    free(decomp);
    gpu_compress_fini();
    return ok ? 0 : 1;
}
