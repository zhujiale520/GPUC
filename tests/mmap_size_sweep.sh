#!/bin/bash
set -e

# ============================================================
#  mmap Read Size Sweep
#  Tests mmap read performance with varying file sizes.
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_mmap_$$"
mkdir -p "$TESTDIR"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

echo "========================================"
echo "  mmap Read Size Sweep"
echo "========================================"
printf "${BLUE}%-12s %-15s %-15s %-15s${NC}\n" "Size" "Baseline (ms)" "Hook RAW (ms)" "GPU Compressed (ms)"

for SIZE in 64M 256M 512M 1G; do
    TESTFILE="$TESTDIR/mmap_${SIZE}.bin"

    # Create file via hook (RAW header)
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs=128k \
            --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1

    # Baseline: without hook
    T_BASE=$(python3 - <<PY
import time
s = time.time()
with open('$TESTFILE', 'rb') as f:
    data = f.read()
elapsed = (time.time() - s) * 1000
print(f"{elapsed:.1f}")
PY
)

    # Hook RAW: read via hook before compression
    T_RAW=$(LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 python3 - <<PY
import time
s = time.time()
with open('$TESTFILE', 'rb') as f:
    data = f.read()
elapsed = (time.time() - s) * 1000
print(f"{elapsed:.1f}")
PY
)

    # Compress
    "$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

    # GPU Compressed
    T_COMP=$(LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 python3 - <<PY
import time
s = time.time()
with open('$TESTFILE', 'rb') as f:
    data = f.read()
elapsed = (time.time() - s) * 1000
print(f"{elapsed:.1f}")
PY
)

    printf "%-12s %-15s %-15s %-15s\n" "$SIZE" "$T_BASE" "$T_RAW" "$T_COMP"
    rm -f "$TESTDIR"/*.bin
    sync
    sleep 1
done

rm -rf "$TESTDIR"
