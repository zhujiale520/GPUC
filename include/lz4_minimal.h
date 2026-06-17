/* Minimal lz4.h subset - declarations for runtime liblz4.so.1 */
#ifndef LZ4_MINIMAL_H
#define LZ4_MINIMAL_H

#ifdef __cplusplus
extern "C" {
#endif

int LZ4_compress_default(const char *src, char *dst, int srcSize, int dstCapacity);
int LZ4_compressBound(int inputSize);
int LZ4_decompress_safe(const char *src, char *dst, int compressedSize, int dstCapacity);

#ifdef __cplusplus
}
#endif

#endif
