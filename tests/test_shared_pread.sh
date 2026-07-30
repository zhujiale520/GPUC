#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/gpuc-shared-pread-XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TEST_BIN="$PROJECT_DIR/bin/test_shared_pread"
PLAIN="$TEST_DIR/plain.bin"
mkdir -p "$TEST_DIR/sglz" "$TEST_DIR/lz4"

python3 - "$PLAIN" <<'PY'
import sys

size = 16 * 1024 * 1024
page_size = 4096
with open(sys.argv[1], "wb") as f:
    for page in range(size // page_size):
        value = ((page * 131 + 17) % 251) + 1
        f.write(bytes([value]) * page_size)
PY

for algo in sglz lz4; do
    path="$TEST_DIR/$algo/data.bin"
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$PLAIN" "$path"
    if [[ "$algo" = lz4 ]]; then
        GPUC_ALGO=lz4 "$DAEMON" "$TEST_DIR/$algo" >/dev/null
    else
        "$DAEMON" "$TEST_DIR/$algo" >/dev/null
    fi
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 "$TEST_BIN" "$path"
done

echo "PASS: shared-fd compressed pread regression"
