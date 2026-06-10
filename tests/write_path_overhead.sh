#!/bin/bash
set -e

# ============================================================
#  Write Path Overhead Test
#  Measures write bandwidth with/without hook.
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_wr_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/write.bin"
SIZE="512M"
BS="128k"
RUNTIME=20

echo "========================================"
echo "  Write Path Overhead"
echo "========================================"
printf "%-20s %-15s %-15s\n" "Scenario" "BW(MB/s)" "IOPS"

# Baseline (no hook)
FIO_OUT="$TESTDIR/fio_base.json"
fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
    --rw=write --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
    --output-format=json > "$FIO_OUT" 2>/dev/null
python3 - <<PY
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
job = d['jobs'][0]['write']
print(f"{'Baseline':<20} {job['bw']/1024:<15.1f} {job['iops']:<15.1f}")
PY
rm -f "$TESTFILE"

# Hook RAW
FIO_OUT="$TESTDIR/fio_hook.json"
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
        --output-format=json > "$FIO_OUT" 2>/dev/null
python3 - <<PY
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
job = d['jobs'][0]['write']
print(f"{'Hook RAW':<20} {job['bw']/1024:<15.1f} {job['iops']:<15.1f}")
PY

rm -rf "$TESTDIR"
