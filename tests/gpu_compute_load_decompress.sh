#!/bin/bash
set -e

# ============================================================
#  GPU Compute Load Decompress Test
#  Measures decompression bandwidth while GPU is busy.
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_compute_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/comp.bin"
SIZE="512M"
BS="128k"
RUNTIME=20

echo "[SETUP] Creating test file..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

echo ""
echo "[TEST] Running GPU compute hog in background..."
python3 "$PROJECT_DIR/tests/gpu_compute_hog.py" &
HOG_PID=$!
sleep 5

echo "[TEST] GPU utilization check:"
nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader

echo ""
echo "[TEST] Running fio read while GPU is busy..."
FIO_OUT="$TESTDIR/fio.json"
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=read --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
        --output-format=json > "$FIO_OUT" 2>/dev/null

python3 - <<PY
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
job = d['jobs'][0]['read']
print(f"Bandwidth: {job['bw']/1024:.1f} MB/s")
print(f"IOPS: {job['iops']:.0f}")
print(f"Errors: {job.get('error', 0)}")
PY

# Cleanup
kill $HOG_PID 2>/dev/null || true
wait $HOG_PID 2>/dev/null || true
rm -rf "$TESTDIR"
