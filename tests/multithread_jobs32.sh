#!/bin/bash
set -e

# ============================================================
#  Multithread Scalability — jobs=32 extension
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_mt32_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/mt32.bin"
SIZE="512M"
BS="128k"
RUNTIME=20

if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

echo "[SETUP] Creating test file..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

echo ""
echo "========================================"
echo "  Multithread Scalability — jobs=32"
echo "========================================"
printf "%-10s %-15s %-15s %-15s\n" "Data" "Baseline" "Hook RAW" "GPU Compressed"

for PATTERN in zero rand; do
    # Baseline (no hook)
    FIO_OUT="$TESTDIR/fio_base_${PATTERN}.json"
    fio --name=mt32 --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
        --numjobs=32 --buffer_pattern=0x00 \
        --output-format=json > "$FIO_OUT" 2>/dev/null
    BASE_BW=$(python3 -c "
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
print(f\"{sum(job['read']['bw'] for job in d['jobs'])/1024:.1f}\")
")

    # GPU Compressed (with hook)
    FIO_OUT="$TESTDIR/fio_gpuc_${PATTERN}.json"
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name=mt32 --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
            --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
            --numjobs=32 --buffer_pattern=0x00 \
            --output-format=json > "$FIO_OUT" 2>/dev/null
    GPUC_BW=$(python3 -c "
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
print(f\"{sum(job['read']['bw'] for job in d['jobs'])/1024:.1f}\")
")

    printf "%-10s %-15s %-15s %-15s\n" "$PATTERN" "$BASE_BW" "—" "$GPUC_BW"
    rm -f "$FIO_OUT"
done

rm -rf "$TESTDIR"
