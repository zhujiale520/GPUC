#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/gpuc-concurrent-XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
SIZE_MIB="${GPUC_CONCURRENT_SIZE_MIB:-64}"
SECONDS="${GPUC_CONCURRENT_SECONDS:-3}"
FILE="$TEST_DIR/data.bin"
PRELOAD="$PROJECT_DIR/bin/libgpuhook.so"

gcc -O2 -Wall -Wextra "$PROJECT_DIR/tests/test_concurrent_daemon.c" \
    -o "$PROJECT_DIR/bin/test_concurrent_daemon"

LD_PRELOAD="$PRELOAD" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_concurrent_daemon" create "$FILE" "$SIZE_MIB"

LD_PRELOAD="$PRELOAD" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_concurrent_daemon" held "$FILE" "$SIZE_MIB" "$SECONDS" &
held_pid=$!
LD_PRELOAD="$PRELOAD" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_concurrent_daemon" reopen "$FILE" "$SIZE_MIB" "$SECONDS" &
reopen_pid=$!

sleep 0.1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TEST_DIR"
wait "$held_pid"
wait "$reopen_pid"

python3 - "$FILE" <<'PY'
import sys
with open(sys.argv[1],"rb") as f: h=f.read(25)
assert len(h)==25 and h[:4]==b"CUPG" and h[24]==1, "final file is not COMPRESSED"
PY
LD_PRELOAD="$PRELOAD" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_concurrent_daemon" reopen "$FILE" "$SIZE_MIB" 0.2
echo "PASS: same-path non-flocking readers remained consistent during atomic daemon replacement"
