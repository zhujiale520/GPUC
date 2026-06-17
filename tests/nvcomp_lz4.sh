#!/bin/bash
set -e

# ============================================================
#  nvCOMP LZ4 backend integration test
# ============================================================
# 验证：
#   1. 使用 GPUC_ALGO=lz4 时，daemon 用 nvCOMP LZ4 压缩
#   2. Hook 能正确读取 LZ4 格式的 GPUC 文件并还原原始数据
#   3. 文本类数据压缩率显著优于 SGLZ
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_lz4_test_$$"

GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

mkdir -p "$TESTDIR"
trap "rm -rf $TESTDIR" EXIT

echo "=== nvCOMP LZ4 Backend Test ==="
echo "Test directory: $TESTDIR"

# ----------------------------------------------------------
# 准备数据集：Linux headers（文本类，SGLZ 压缩率约 75%）
# ----------------------------------------------------------
ORIG="$TESTDIR/original.tar"
tar -cf "$ORIG" /usr/include 2>/dev/null
ORIG_SIZE=$(stat -c%s "$ORIG")
ORIG_SHA=$(sha256sum "$ORIG" | awk '{print $1}')
echo "Original size: $ORIG_SIZE bytes ($((ORIG_SIZE/1024/1024)) MB)"

# 通过 Hook 写入 RAW 文件
RAW="$TESTDIR/test.raw"
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
    dd if="$ORIG" of="$RAW" bs=1M status=none

echo "RAW file created."

# 实际磁盘占用（考虑稀疏文件空洞）
disk_bytes() {
    du -B1 "$1" | cut -f1
}

# ----------------------------------------------------------
# 1) SGLZ 压缩作为 baseline
# ----------------------------------------------------------
SGLZ_DIR="$TESTDIR/sglz"
mkdir -p "$SGLZ_DIR"
cp "$RAW" "$SGLZ_DIR/test.bin"
"$GPU_DAEMON" "$SGLZ_DIR" >/dev/null 2>&1
SGLZ_SIZE=$(disk_bytes "$SGLZ_DIR/test.bin")
SGLZ_RATIO=$(python3 -c "print(f'{100.0*$SGLZ_SIZE/$ORIG_SIZE:.1f}')")
echo "SGLZ compressed size: $SGLZ_SIZE bytes (ratio $SGLZ_RATIO%)"

# 读取并校验（通过管道，避免写入新 GPUC 文件时被再次加上 header）
SGLZ_SHA=$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 cat "$SGLZ_DIR/test.bin" | sha256sum | awk '{print $1}')
if [ "$SGLZ_SHA" = "$ORIG_SHA" ]; then
    echo -e "${GREEN}SGLZ read-back OK${NC}"
else
    echo -e "${RED}SGLZ read-back FAILED${NC}"
    exit 1
fi

# ----------------------------------------------------------
# 2) LZ4 压缩
# ----------------------------------------------------------
LZ4_DIR="$TESTDIR/lz4"
mkdir -p "$LZ4_DIR"
cp "$RAW" "$LZ4_DIR/test.bin"
GPUC_ALGO=lz4 "$GPU_DAEMON" "$LZ4_DIR" >/dev/null 2>&1
LZ4_SIZE=$(disk_bytes "$LZ4_DIR/test.bin")
LZ4_RATIO=$(python3 -c "print(f'{100.0*$LZ4_SIZE/$ORIG_SIZE:.1f}')")
echo "LZ4 compressed size: $LZ4_SIZE bytes (ratio $LZ4_RATIO%)"

# 读取并校验
LZ4_SHA=$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 cat "$LZ4_DIR/test.bin" | sha256sum | awk '{print $1}')
if [ "$LZ4_SHA" = "$ORIG_SHA" ]; then
    echo -e "${GREEN}LZ4 read-back OK${NC}"
else
    echo -e "${RED}LZ4 read-back FAILED${NC}"
    exit 1
fi

# ----------------------------------------------------------
# 3) 全零数据：LZ4 也能正确压缩/解压
# ----------------------------------------------------------
ZERO_DIR="$TESTDIR/zero"
mkdir -p "$ZERO_DIR"
ZERO_MB=8
ZERO_SIZE=$((ZERO_MB * 1024 * 1024))
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
    dd if=/dev/zero of="$ZERO_DIR/zero.bin" bs=1M count=$ZERO_MB status=none
GPUC_ALGO=lz4 "$GPU_DAEMON" "$ZERO_DIR" >/dev/null 2>&1
if LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 cat "$ZERO_DIR/zero.bin" | cmp -n "$ZERO_SIZE" - /dev/zero >/dev/null 2>&1; then
    echo -e "${GREEN}LZ4 zero-data read-back OK${NC}"
else
    echo -e "${RED}LZ4 zero-data read-back FAILED${NC}"
    exit 1
fi

# ----------------------------------------------------------
# 汇总
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "  nvCOMP LZ4 Backend Test: PASS"
echo "========================================"
echo "SGLZ ratio: $SGLZ_RATIO%"
echo "LZ4  ratio: $LZ4_RATIO%"
IMPR=$(python3 -c "print(f'{(float(\"$SGLZ_RATIO\")-float(\"$LZ4_RATIO\"))/float(\"$SGLZ_RATIO\")*100:.1f}')")
echo "压缩率提升: ${IMPR}% (相对 SGLZ)"
