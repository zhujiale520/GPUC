#!/bin/bash
set -e

# ============================================================
#  Metadata Operation Performance — stat/ls/find 拦截开销
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_metadata_$$"
mkdir -p "$TESTDIR"

# 确保编译产物
if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

NUM_FILES=10000
FILE_SIZE=4096

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "========================================"
echo "  Metadata Operation Performance"
echo "========================================"
echo "Test dir: $TESTDIR"
echo "Files: $NUM_FILES x ${FILE_SIZE}B"
echo ""

# 创建文件（不带 hook 的 baseline）
echo "[SETUP] Creating $NUM_FILES baseline files..."
for i in $(seq 1 $NUM_FILES); do
    dd if=/dev/zero of="$TESTDIR/base_$i.bin" bs=$FILE_SIZE count=1 status=none
done

# 复制一份给 hook 使用
cp -r "$TESTDIR" "$TESTDIR-hook"

# Baseline: stat / ls / find 无 hook
echo ""
echo -e "${BLUE}>>> Baseline (no hook)${NC}"

t0=$(date +%s%N)
for i in $(seq 1 $NUM_FILES); do
    stat -c %s "$TESTDIR/base_$i.bin" >/dev/null
done
t1=$(date +%s%N)
BASE_STAT_US=$(( (t1 - t0) / 1000 ))
echo "  stat x$NUM_FILES: ${BASE_STAT_US} us"

t0=$(date +%s%N)
ls -l "$TESTDIR" >/dev/null
t1=$(date +%s%N)
BASE_LS_US=$(( (t1 - t0) / 1000 ))
echo "  ls -l: ${BASE_LS_US} us"

t0=$(date +%s%N)
find "$TESTDIR" -maxdepth 1 -type f | wc -l >/dev/null
t1=$(date +%s%N)
BASE_FIND_US=$(( (t1 - t0) / 1000 ))
echo "  find: ${BASE_FIND_US} us"

# Hook RAW: 先用 hook 打开并关闭，让 header 附加
echo ""
echo -e "${BLUE}>>> Hook RAW (with LD_PRELOAD)${NC}"

for i in $(seq 1 $NUM_FILES); do
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        dd if=/dev/zero of="$TESTDIR-hook/hook_$i.bin" bs=$FILE_SIZE count=1 status=none
done

t0=$(date +%s%N)
for i in $(seq 1 $NUM_FILES); do
    stat -c %s "$TESTDIR-hook/hook_$i.bin" >/dev/null
done
t1=$(date +%s%N)
HOOK_STAT_US=$(( (t1 - t0) / 1000 ))
echo "  stat x$NUM_FILES: ${HOOK_STAT_US} us ($(echo "scale=1; $HOOK_STAT_US * 100 / $BASE_STAT_US" | bc)% of baseline)"

t0=$(date +%s%N)
ls -l "$TESTDIR-hook" >/dev/null
t1=$(date +%s%N)
HOOK_LS_US=$(( (t1 - t0) / 1000 ))
echo "  ls -l: ${HOOK_LS_US} us ($(echo "scale=1; $HOOK_LS_US * 100 / $BASE_LS_US" | bc)% of baseline)"

t0=$(date +%s%N)
find "$TESTDIR-hook" -maxdepth 1 -type f | wc -l >/dev/null
t1=$(date +%s%N)
HOOK_FIND_US=$(( (t1 - t0) / 1000 ))
echo "  find: ${HOOK_FIND_US} us ($(echo "scale=1; $HOOK_FIND_US * 100 / $BASE_FIND_US" | bc)% of baseline)"

# 汇总
echo ""
echo "========================================"
echo "  Metadata Performance Summary"
echo "========================================"
printf "${GREEN}%-10s %12s %12s %12s${NC}\n" "Op" "Baseline" "Hook" "Overhead"
echo "-----------------------------------------------"
printf "%-10s %12d %12d %12.1fx\n" "stat" "$BASE_STAT_US" "$HOOK_STAT_US" "$(echo "scale=1; $HOOK_STAT_US / $BASE_STAT_US" | bc)"
printf "%-10s %12d %12d %12.1fx\n" "ls -l" "$BASE_LS_US" "$HOOK_LS_US" "$(echo "scale=1; $HOOK_LS_US / $BASE_LS_US" | bc)"
printf "%-10s %12d %12d %12.1fx\n" "find" "$BASE_FIND_US" "$HOOK_FIND_US" "$(echo "scale=1; $HOOK_FIND_US / $BASE_FIND_US" | bc)"

rm -rf "$TESTDIR" "$TESTDIR-hook"
