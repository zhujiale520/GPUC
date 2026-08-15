/*
 * CoreX build stub for the NVIDIA-only nvCOMP LZ4 backend.
 *
 * The portable SGLZ CUDA backend remains enabled.  Files encoded as LZ4 are
 * still readable through cpu_lz4.c; requests to create/use GPU LZ4 report
 * unavailable so callers can fall back explicitly.
 */

#include "gpu_compress_api.h"

#include <string.h>

int gpu_lz4_init(void) { return -1; }
void gpu_lz4_fini(void) { }

int gpu_lz4_compress_batch(int n,
                           const uint8_t **in_bufs, const size_t *in_lens,
                           uint8_t **out_bufs, const size_t *out_caps,
                           size_t *out_lens) {
    (void)n; (void)in_bufs; (void)in_lens; (void)out_bufs;
    (void)out_caps; (void)out_lens;
    return -1;
}

int gpu_lz4_decompress_batch(int n,
                             const uint8_t **in_bufs, const size_t *in_lens,
                             uint8_t **out_bufs, const size_t *out_lens) {
    (void)n; (void)in_bufs; (void)in_lens; (void)out_bufs; (void)out_lens;
    return -1;
}

int gpu_lz4_get_last_profile(gpu_lz4_profile_t *profile) {
    if (profile) memset(profile, 0, sizeof(*profile));
    return -1;
}

int gpu_lz4_host_alloc(void **ptr, size_t size) {
    (void)ptr; (void)size;
    return -1;
}

void gpu_lz4_host_free(void *ptr) { (void)ptr; }

int gpu_lz4_compress_128k(const uint8_t *in, uint8_t *out, size_t out_cap) {
    (void)in; (void)out; (void)out_cap;
    return -1;
}

int gpu_lz4_decompress_128k(const uint8_t *in, size_t in_len,
                            uint8_t *out, size_t out_len) {
    (void)in; (void)in_len; (void)out; (void)out_len;
    return -1;
}
