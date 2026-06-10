#!/bin/bash
set -e

# ============================================================
#  btrfs zstd vs GPUC comparison script
#  Requires: sudo privileges to create loopback + mkfs.btrfs
#  Usage:    sudo ./tests/btrfs_compare.sh
# ============================================================

if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root to create loopback devices."
    echo "Usage: sudo $0"
    exit 1
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GPUC_DIR="/tmp/gpuc_btrfs_gpuc_$$"
BTRFS_IMG="/tmp/gpuc_btrfs_img_$$.img"
BTRFS_MNT="/tmp/gpuc_btrfs_mnt_$$"
SIZE="512M"
BS="128k"
RUNTIME=20

mkdir -p "$GPUC_DIR" "$BTRFS_MNT"

# ---- Build GPUC if needed ----
if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

# ---- GPUC setup ----
echo "[GPUC] Creating test file..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$GPUC_DIR/test.bin" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$GPUC_DIR" >/dev/null 2>&1

# ---- btrfs setup ----
echo "[BTRFS] Creating ${SIZE} btrfs image..."
dd if=/dev/zero of="$BTRFS_IMG" bs=1M count=1024 status=none
DEV=$(losetup -f --show "$BTRFS_IMG")
mkfs.btrfs -f "$DEV" >/dev/null
mount -o compress=zstd "$DEV" "$BTRFS_MNT"

# Write same data to btrfs
fio --name=write --filename="$BTRFS_MNT/test.bin" --size="$SIZE" --bs="$BS" \
    --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1

# ---- Run comparisons ----
echo ""
echo "========================================"
echo "  btrfs zstd vs GPUC Comparison"
echo "========================================"
printf "%-25s %-15s %-15s\n" "Metric" "btrfs zstd" "GPUC"
echo "-------------------------------------------------------"

run_fio() {
    local path=$1
    local preload=$2
    local out="/tmp/gpuc_btrfs_fio_$$.json"
    if [ -n "$preload" ]; then
        LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 \
            fio --name=cmp --filename="$path" --size="$SIZE" --bs="$BS" \
                --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
                --output-format=json > "$out" 2>/dev/null
    else
        fio --name=cmp --filename="$path" --size="$SIZE" --bs="$BS" \
            --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
            --output-format=json > "$out" 2>/dev/null
    fi
    python3 -c "
import json
with open('$out') as f:
    d = json.load(f)
job = d['jobs'][0]['read']
print(f\"{job['bw']/1024:.1f}\")
"
}

BTRFS_BW=$(run_fio "$BTRFS_MNT/test.bin" "")
GPUC_BW=$(run_fio "$GPUC_DIR/test.bin" "$PROJECT_DIR/bin/libgpuhook.so")
printf "%-25s %-15s %-15s\n" "Seq Read 128k (MB/s)" "$BTRFS_BW" "$GPUC_BW"

# Space usage
BTRFS_BLOCKS=$(stat -c %b "$BTRFS_MNT/test.bin")
GPUC_BLOCKS=$(stat -c %b "$GPUC_DIR/test.bin")
printf "%-25s %-15s %-15s\n" "Blocks (512B)" "$BTRFS_BLOCKS" "$GPUC_BLOCKS"

# Cleanup
umount "$BTRFS_MNT"
losetup -d "$DEV"
rm -f "$BTRFS_IMG"
rm -rf "$GPUC_DIR" "$BTRFS_MNT"
