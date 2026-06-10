#!/bin/bash
set -e

# ============================================================
#  Write-Read Consistency Workload Simulation
#  Simulates real app pattern: write -> randread -> compress -> read + md5
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_consist_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/wrkld.bin"
BS="128k"
SIZE="256M"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

echo "[PHASE 1/4] Write ${SIZE} random data..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=phase1 --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0xdeadbeef --direct=0 --ioengine=sync \
        --output-format=json > "$TESTDIR/phase1.json" 2>/dev/null
MD5_BEFORE=$(LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    dd if="$TESTFILE" bs=1M status=none 2>/dev/null | md5sum | awk '{print $1}')
echo "  MD5 (after write, hook-read): $MD5_BEFORE"

echo ""
echo "[PHASE 2/4] Random read 25% of data..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=phase2 --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=randread --runtime=10 --time_based --direct=0 --ioengine=sync \
        --output-format=json > "$TESTDIR/phase2.json" 2>/dev/null

echo ""
echo "[PHASE 3/4] Daemon compress..."
COMPRESS_START=$(date +%s%3N)
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1
COMPRESS_END=$(date +%s%3N)
COMPRESS_MS=$((COMPRESS_END - COMPRESS_START))
echo "  Daemon compression time: ${COMPRESS_MS} ms"

# Show compression stats
python3 - <<PY
import os, glob
total_raw = 0
total_phys = 0
for f in glob.glob('$TESTDIR/*.bin'):
    try:
        st = os.stat(f)
        total_phys += st.st_blocks * 512
        total_raw += st.st_size
    except:
        pass
if total_raw > 0:
    ratio = total_phys / total_raw * 100
    print(f"  Physical blocks: {total_phys/1024/1024:.2f} MB / Raw: {total_raw/1024/1024:.2f} MB ({ratio:.1f}%)")
PY

echo ""
echo "[PHASE 4/4] Read compressed data and verify MD5..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=phase4 --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=read --runtime=10 --time_based --direct=0 --ioengine=sync \
        --output-format=json > "$TESTDIR/phase4.json" 2>/dev/null

# Use dd to fully read back and compute MD5
MD5_AFTER=$(LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    dd if="$TESTFILE" bs=1M status=none 2>/dev/null | md5sum | awk '{print $1}')
echo "  MD5 (after compress+read): $MD5_AFTER"

echo ""
echo "========================================"
echo "  Write-Read Consistency Result"
echo "========================================"
if [ "$MD5_BEFORE" = "$MD5_AFTER" ]; then
    echo -e "${GREEN}PASS: MD5 matches.${NC}"
    echo "  Data integrity preserved through write -> randread -> compress -> read."
else
    echo -e "${RED}FAIL: MD5 mismatch!${NC}"
    echo "  Before: $MD5_BEFORE"
    echo "  After:  $MD5_AFTER"
fi

rm -rf "$TESTDIR"
