#!/bin/bash
set -e

# ============================================================
#  GPU Memory Pressure Scan
#  Measures decompression bandwidth under varying GPU memory load.
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_mem_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/mem.bin"
BS="128k"
SIZE="512M"
RUNTIME=20

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

echo "[SETUP] Creating test file..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

POINTS="0 1 2 4 8 14 20 28"
CSV="$TESTDIR/mem_scan.csv"
echo "mem_gb,bw_mb,status" > "$CSV"

echo ""
echo "========================================"
echo "  GPU Memory Pressure Scan"
echo "========================================"
printf "${BLUE}%-10s %-15s %-10s${NC}\n" "Mem(GB)" "BW(MB/s)" "Status"

for MEM in $POINTS; do
    # Launch Python memory hog in background
    PY_PID=""
    if [ "$MEM" -gt 0 ]; then
        python3 - <<PY &
import torch, time
size_gb = $MEM
size_bytes = size_gb * 1024**3
try:
    x = torch.empty(size_bytes // 4, dtype=torch.float32, device='cuda')
    x.fill_(1.0)
    while True:
        time.sleep(1)
except Exception as e:
    print(f"mem_hog error: {e}")
PY
        PY_PID=$!
        sleep 2
    fi

    # Run fio
    FIO_OUT="$TESTDIR/fio_${MEM}gb.json"
    if LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name=scan --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
            --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
            --output-format=json > "$FIO_OUT" 2>/dev/null; then
        BW=$(python3 -c "
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
print(f\"{d['jobs'][0]['read']['bw']/1024:.1f}\")
")
        ERR="ok"
    else
        BW="0"
        ERR="fail"
    fi

    # Cleanup memory hog
    if [ -n "$PY_PID" ]; then
        kill $PY_PID 2>/dev/null || true
        wait $PY_PID 2>/dev/null || true
    fi
    python3 -c "import torch; torch.cuda.empty_cache()" 2>/dev/null || true

    printf "%-10s %-15s %-10s\n" "$MEM" "$BW" "$ERR"
    echo "${MEM},${BW},${ERR}" >> "$CSV"
done

echo ""
echo "CSV saved: $CSV"
rm -rf "$TESTDIR"
