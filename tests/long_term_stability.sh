#!/bin/bash
set -e

# ============================================================
#  Long-term Stability Test — 30 min sustained read
#  Measures bandwidth consistency over time.
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_stab_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/stab.bin"
DURATION=1800   # 30 minutes
BS="128k"
SIZE="1G"
SAMPLE_INT=5    # sample every 5 seconds via fio latency logs

BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

echo "[SETUP] Creating ${SIZE} test file..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

echo ""
echo "[RUN] Sustained read for ${DURATION}s (samples every ${SAMPLE_INT}s)..."
FIO_OUT="$TESTDIR/fio.json"
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=stab --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=read --runtime="$DURATION" --time_based --direct=0 --ioengine=sync \
        --output-format=json > "$FIO_OUT" 2>/dev/null

echo ""
echo "========================================"
echo "  Long-term Stability Result"
echo "========================================"

python3 - <<PY
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
job = d['jobs'][0]['read']
bw_mb = job['bw'] / 1024
iops = job['iops']
lat_us = job['lat_ns']['mean'] / 1000.0
lat_p95 = job['lat_ns']['percentile']['95.000000'] / 1000.0
lat_p99 = job['lat_ns']['percentile']['99.000000'] / 1000.0
err = job.get('error', 0)
print(f"{'Duration:':<20} 30 min")
print(f"{'Read bandwidth:':<20} {bw_mb:.1f} MB/s")
print(f"{'IOPS:':<20} {iops:.0f}")
print(f"{'Mean latency:':<20} {lat_us:.1f} us")
print(f"{'P95 latency:':<20} {lat_p95:.1f} us")
print(f"{'P99 latency:':<20} {lat_p99:.1f} us")
print(f"{'Errors:':<20} {err}")
if err == 0:
    print(f"\n{chr(27)}[0;32mPASS: no errors during 30-minute sustained read.{chr(27)}[0m")
else:
    print(f"\n{chr(27)}[0;31mFAIL: {err} errors occurred.{chr(27)}[0m")
PY

rm -rf "$TESTDIR"
