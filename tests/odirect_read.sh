#!/bin/bash
set -e

# ============================================================
#  O_DIRECT Read Test — check compressed-file read with O_DIRECT
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_odirect_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/odirect.bin"
BS="128k"
SIZE="256M"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
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

echo ""
echo "[TEST] O_DIRECT read on compressed file..."
FIO_OUT="$TESTDIR/fio.json"
if LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=odirect --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=read --runtime=30 --time_based --direct=1 --ioengine=sync \
        --output-format=json > "$FIO_OUT" 2>"$TESTDIR/fio.err"; then
    BW=$(python3 -c "
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
print(f\"{d['jobs'][0]['read']['bw']/1024:.1f}\")
")
    ERR=$(python3 -c "
import json
with open('$FIO_OUT') as f:
    d = json.load(f)
print(d['jobs'][0]['read'].get('error',0))
")
    echo -e "${GREEN}O_DIRECT read completed.${NC}"
    echo "  Bandwidth: ${GREEN}${BW} MB/s${NC}"
    echo "  Errors: ${GREEN}${ERR}${NC}"
else
    echo -e "${RED}O_DIRECT read FAILED.${NC}"
    echo "FIO stderr:"
    sed 's/^/  /' "$TESTDIR/fio.err"
fi

rm -rf "$TESTDIR"
