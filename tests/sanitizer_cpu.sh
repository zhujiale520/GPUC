#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/gpuc-sanitizer-XXXXXX)"
TEST_DIR="$(mktemp -d /tmp/gpuc-sanitizer-data-XXXXXX)"
trap 'rm -rf -- "$BUILD_DIR" "$TEST_DIR"' EXIT

SAN="-fsanitize=address,undefined -fno-omit-frame-pointer"
if [[ -f "$PROJECT_DIR/third_party/lz4/liblz4.so" ]]; then
    LZ4=(-L"$PROJECT_DIR/third_party/lz4" -Wl,-rpath,"$PROJECT_DIR/third_party/lz4" -llz4)
else
    LZ4=(-Wl,-l:liblz4.so.1)
fi
gcc -shared -fPIC -O1 -g $SAN -DCPU_ONLY_BUILD -I"$PROJECT_DIR/include" \
    "$PROJECT_DIR/src/hook.c" "$PROJECT_DIR/src/cpu_compress.c" "$PROJECT_DIR/src/cpu_lz4.c" \
    -o "$BUILD_DIR/libcpuhook_san.so" -ldl -lpthread "${LZ4[@]}"
gcc -O1 -g $SAN "$PROJECT_DIR/tests/test_posix_semantics.c" \
    -o "$BUILD_DIR/test_posix_semantics"

asan="$(gcc -print-file-name=libasan.so)"
ubsan="$(gcc -print-file-name=libubsan.so)"
preload="$asan:$ubsan:$BUILD_DIR/libcpuhook_san.so"
# LeakSanitizer cannot run in several ptrace/seccomp sandboxes. Keep ASan and
# UBSan always on; enable leak detection explicitly in an unrestricted CI job.
detect_leaks="${GPUC_LSAN:-0}"
[[ "$detect_leaks" == 1 ]] || echo "INFO: LeakSanitizer disabled (set GPUC_LSAN=1 outside ptrace sandboxes)"
export ASAN_OPTIONS="detect_leaks=$detect_leaks:halt_on_error=1"
export UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1"

LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 \
    "$BUILD_DIR/test_posix_semantics" raw "$TEST_DIR/raw.bin"
LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 \
    "$BUILD_DIR/test_posix_semantics" rename "$TEST_DIR/rename-source"

echo "PASS: ASan/UBSan CPU Hook smoke"
