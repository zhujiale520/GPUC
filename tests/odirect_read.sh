#!/bin/bash
set -e

# ============================================================
#  O_DIRECT Read Test — check compressed-file read with O_DIRECT
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_odirect_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/odirect.bin"
BS="${GPUC_BS:-128k}"
SIZE="${GPUC_SIZE:-256M}"
RUNTIME="${GPUC_RUNTIME:-30}"
RESULT_DIR="${GPUC_RESULT_DIR:-}"
trap 'rm -rf -- "$TESTDIR"' EXIT

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
python3 - "$TESTFILE" <<'PY'
import struct,sys
with open(sys.argv[1],"rb") as f: header=f.read(56)
flags=struct.unpack_from("<H",header,26)[0]
header_size=struct.unpack_from("<Q",header,32)[0]
assert flags & 1, "aligned-direct format flag missing"
assert header_size % 4096 == 0, header_size
print(f"[CHECK] aligned header_size={header_size}")
PY

HEADER_SIZE=$(python3 - "$TESTFILE" <<'PY'
import struct,sys
with open(sys.argv[1],"rb") as f: header=f.read(56)
print(struct.unpack_from("<Q",header,32)[0])
PY
)

make -C "$PROJECT_DIR" bin/test_odirect_compressed >/dev/null
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_odirect_compressed" "$TESTFILE"

echo ""
echo "[TEST] O_DIRECT read on compressed file..."
FIO_OUT="$TESTDIR/fio.json"
if LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=odirect --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=read --runtime="$RUNTIME" --time_based --direct=1 --ioengine=sync \
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
    exit 1
fi

if [ -n "$RESULT_DIR" ]; then
    mkdir -p "$RESULT_DIR"
    cp "$FIO_OUT" "$RESULT_DIR/fio_odirect.json"
    cp "$TESTDIR/fio.err" "$RESULT_DIR/fio_odirect.err"
    {
        echo "date_utc=$(date -u +%FT%TZ)"
        echo "hostname=$(hostname)"
        echo "kernel=$(uname -r)"
        echo "filesystem=$(findmnt -no FSTYPE -T "$PROJECT_DIR")"
        echo "source=$(findmnt -no SOURCE -T "$PROJECT_DIR")"
        echo "gpu=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | head -n1)"
        echo "size=$SIZE"
        echo "block_size=$BS"
        echo "runtime_s=$RUNTIME"
        echo "header_size=$HEADER_SIZE"
        echo "direct_flag_retained=yes"
        echo "fio_errors=$ERR"
        echo "read_mib_s=$BW"
    } > "$RESULT_DIR/environment.txt"
    echo "Saved result: $RESULT_DIR"
fi
