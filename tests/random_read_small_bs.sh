#!/bin/bash
set -e

# ============================================================
#  Small Block Size Random Read Test
#  Tests 4k / 16k / 64k / 128k random read on compressed files.
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_randbs_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/rand.bin"
SIZE="256M"
RUNTIME=10

BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

echo "[SETUP] Creating ${SIZE} zero test file..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs=128k \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

echo ""
echo "========================================"
echo "  Random Read with Small Block Sizes"
echo "========================================"
printf "${BLUE}%-8s %-15s %-12s %-15s${NC}\n" "BS" "IOPS" "BW(kB/s)" "Lat(us)"

for BS in 4k 16k 64k 128k; do
    FIO_OUT="$TESTDIR/fio_${BS}.json"
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name=rand --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
            --rw=randread --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
            --output-format=json > "$FIO_OUT" 2>/dev/null

    python3 - <<PY
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
job = d['jobs'][0]['read']
iops = job['iops']
bw_kb = job['bw']
lat_us = job['lat_ns']['mean'] / 1000.0
print(f"{'$BS':<8} {iops:<15.1f} {bw_kb:<12.1f} {lat_us:<15.1f}")
PY
done

rm -rf "$TESTDIR"
