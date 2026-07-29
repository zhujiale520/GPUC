#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/gpuc-posix-XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

gcc -O2 -Wall -Wextra "$PROJECT_DIR/tests/test_posix_semantics.c" \
    -o "$PROJECT_DIR/bin/test_posix_semantics"

PRELOAD="$PROJECT_DIR/bin/libcpuhook.so"
RAW_PATH="$TEST_DIR/raw.bin"
COMP_PATH="$TEST_DIR/compressed.bin"

LD_PRELOAD="$PRELOAD" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_posix_semantics" raw "$RAW_PATH"

LD_PRELOAD="$PRELOAD" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_hook" write "$COMP_PATH" 262144
"$PROJECT_DIR/bin/cpu_compress_daemon" "$TEST_DIR"
LD_PRELOAD="$PRELOAD" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_posix_semantics" compressed "$COMP_PATH"
LD_PRELOAD="$PRELOAD" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_posix_semantics" rename "$TEST_DIR/rename-source"

echo "PASS: POSIX semantics smoke test"
