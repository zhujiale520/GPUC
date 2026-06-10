#!/bin/bash
set -e

# ============================================================
#  Massive Small Files — 海量小文件批量场景
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_massive_$$"
mkdir -p "$TESTDIR"

if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ] || [ ! -f "$PROJECT_DIR/bin/gpu_compress_daemon" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

NUM_FILES=10000
FILE_SIZE=512

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "========================================"
echo "  Massive Small Files Test"
echo "========================================"
echo "Files: $NUM_FILES x ${FILE_SIZE}B"
echo ""

# 1. Baseline 创建
echo -e "${BLUE}>>> Baseline: create $NUM_FILES files${NC}"
t0=$(date +%s%N)
for i in $(seq 1 $NUM_FILES); do
    printf 'x%.0s' $(seq 1 $FILE_SIZE) > "$TESTDIR/base_$i.bin"
done
t1=$(date +%s%N)
BASE_CREATE_MS=$(( (t1 - t0) / 1000000 ))
echo "  Create: ${BASE_CREATE_MS} ms"

# 2. Baseline 读取
t0=$(date +%s%N)
for i in $(seq 1 $NUM_FILES); do
    cat "$TESTDIR/base_$i.bin" >/dev/null
done
t1=$(date +%s%N)
BASE_READ_MS=$(( (t1 - t0) / 1000000 ))
echo "  Read: ${BASE_READ_MS} ms"

BASE_PHYS=$(du -sb "$TESTDIR" | awk '{print $1}')
echo "  Physical size: $(echo "$BASE_PHYS" | numfmt --to=iec)"

# 清理
rm -rf "$TESTDIR"/*

# 3. Hook RAW 创建
echo ""
echo -e "${BLUE}>>> Hook RAW: create $NUM_FILES files${NC}"
t0=$(date +%s%N)
for i in $(seq 1 $NUM_FILES); do
    printf 'x%.0s' $(seq 1 $FILE_SIZE) | LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        dd of="$TESTDIR/hook_$i.bin" bs=$FILE_SIZE count=1 status=none
done
t1=$(date +%s%N)
HOOK_CREATE_MS=$(( (t1 - t0) / 1000000 ))
echo "  Create: ${HOOK_CREATE_MS} ms"

# 4. Hook RAW 读取
t0=$(date +%s%N)
for i in $(seq 1 $NUM_FILES); do
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        cat "$TESTDIR/hook_$i.bin" >/dev/null
done
t1=$(date +%s%N)
HOOK_READ_MS=$(( (t1 - t0) / 1000000 ))
echo "  Read: ${HOOK_READ_MS} ms"

# 5. Daemon 压缩 + Inline 读取
echo ""
echo -e "${BLUE}>>> Daemon compress + Inline read${NC}"
t0=$(date +%s%N)
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1
t1=$(date +%s%N)
DAEMON_MS=$(( (t1 - t0) / 1000000 ))
echo "  Daemon compress: ${DAEMON_MS} ms"

# 验证 inline 比例
INLINE_COUNT=$(python3 << EOF
import struct, os
count = 0
for f in os.listdir('$TESTDIR'):
    path = os.path.join('$TESTDIR', f)
    if not os.path.isfile(path):
        continue
    with open(path, 'rb') as fh:
        data = fh.read(28)
        if len(data) >= 28:
            magic = struct.unpack('<I', data[0:4])[0]
            state = data[24]
            if magic == 0x47505543 and state == 3:
                count += 1
print(count)
EOF
)
echo "  Inline files: $INLINE_COUNT / $NUM_FILES"

# Inline 读取
t0=$(date +%s%N)
for i in $(seq 1 $NUM_FILES); do
    [ -f "$TESTDIR/hook_$i.bin" ] && LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        cat "$TESTDIR/hook_$i.bin" >/dev/null
done
t1=$(date +%s%N)
INLINE_READ_MS=$(( (t1 - t0) / 1000000 ))
echo "  Inline read: ${INLINE_READ_MS} ms"

INLINE_PHYS=$(du -sb "$TESTDIR" | awk '{print $1}')
echo "  Physical size: $(echo "$INLINE_PHYS" | numfmt --to=iec)"

# 汇总
echo ""
echo "========================================"
echo "  Massive Small Files Summary"
echo "========================================"
printf "${GREEN}%-25s %12s %12s %12s${NC}\n" "Metric" "Baseline" "Hook RAW" "Inline"
echo "------------------------------------------------------------"
printf "%-25s %12s %12s %12s\n" "Create time (ms)" "$BASE_CREATE_MS" "$HOOK_CREATE_MS" "-"
printf "%-25s %12s %12s %12s\n" "Read time (ms)" "$BASE_READ_MS" "$HOOK_READ_MS" "$INLINE_READ_MS"
printf "%-25s %12s %12s %12s\n" "Physical size" "$(echo "$BASE_PHYS" | numfmt --to=iec)" "$(echo "$BASE_PHYS" | numfmt --to=iec)" "$(echo "$INLINE_PHYS" | numfmt --to=iec)"
printf "%-25s %12s %12s %12s\n" "Daemon compress (ms)" "-" "-" "$DAEMON_MS"

rm -rf "$TESTDIR"
