#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "gpu_compress_api.h"

#define BLOCK (128U * 1024U)
#define CAP (BLOCK + BLOCK / 255U + 64U)

int main(void) {
    uint8_t *input = malloc(BLOCK);
    uint8_t *compressed = malloc(CAP);
    uint8_t *decoded = malloc(BLOCK);
    if (!input || !compressed || !decoded) return 1;
    for (size_t i = 0; i < BLOCK; i++)
        input[i] = (uint8_t)((i / 4096U * 37U) % 251U);

    const uint8_t *inputs[1] = {input};
    size_t input_lens[1] = {BLOCK};
    uint8_t *outputs[1] = {compressed};
    size_t caps[1] = {CAP};
    size_t compressed_lens[1] = {0};
    if (cpu_lz4_compress_batch(1, inputs, input_lens, outputs, caps,
                               compressed_lens) != 1)
        return 1;

    const uint8_t *stored[1] = {compressed};
    uint8_t *roundtrip[1] = {decoded};
    size_t decoded_lens[1] = {BLOCK};
    if (cpu_lz4_decompress_batch(1, stored, compressed_lens, roundtrip,
                                 decoded_lens) != 1 ||
        memcmp(input, decoded, BLOCK) != 0)
        return 1;

    /* Exercise raw flag and malformed flag validation too. */
    compressed[0] = 0;
    memcpy(compressed + 1, input, BLOCK);
    compressed_lens[0] = BLOCK + 1U;
    if (cpu_lz4_decompress_batch(1, stored, compressed_lens, roundtrip,
                                 decoded_lens) != 1)
        return 1;
    compressed[0] = 0x7f;
    if (cpu_lz4_decompress_batch(1, stored, compressed_lens, roundtrip,
                                 decoded_lens) >= 0)
        return 1;

    free(input); free(compressed); free(decoded);
    puts("PASS: CPU LZ4 compressed/raw/malformed paths");
    return 0;
}
