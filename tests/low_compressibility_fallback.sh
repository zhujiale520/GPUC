#!/bin/bash
set -e

# ============================================================
#  Low Compressibility Fallback Test
# ============================================================
# 验证 daemon 对整体压缩率不足的文件保持 RAW 状态，
# 避免低可压缩数据进入 GPU 解压慢路径。
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_lowcomp_fallback_$$"
RESULTDIR="/tmp/gpuc_lowcomp_fallback_results_$$"

mkdir -p "$TESTDIR" "$RESULTDIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAIL=$((FAIL+1)); }

check_state() {
    python3 - << PY
import struct, sys
with open('$1', 'rb') as f:
    magic = struct.unpack('<I', f.read(4))[0]
    if magic != 0x47505543:
        sys.exit(2)
    f.seek(24)
    state = struct.unpack('<B', f.read(1))[0]
    sys.exit(state)
PY
    return $?
}

generate_file() {
    local path="$1"
    local ratio_pct="$2"  # 0-100
    local size="$3"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 python3 - << PY
import random
path='$path'
size=$size
ratio=$ratio_pct / 100.0
random.seed(42)
with open(path, 'wb') as f:
    for _ in range(size // 4096):
        block = bytearray(4096)
        for i in range(4096):
            block[i] = 0 if random.random() < ratio else random.randint(0, 255)
        f.write(block)
PY
}

echo "========================================"
echo "  Low Compressibility Fallback Test"
echo "========================================"
echo "测试目录: $TESTDIR"
echo ""

for RATIO in 0 25 50 100; do
    echo -e "${YELLOW}### 可压缩率 ${RATIO}% ###${NC}"
    FILE="$TESTDIR/ratio_${RATIO}.bin"
    generate_file "$FILE" "$RATIO" $((64*1024*1024))
    BEFORE_SIZE=$(stat -c%s "$FILE")

    "$GPU_DAEMON" "$TESTDIR" >/dev/null 2>&1

    STATE=$(check_state "$FILE"; echo $?)
    AFTER_SIZE=$(stat -c%s "$FILE")

    # 期望：0% 和 25% 保持 RAW；50% 可能保持 RAW 或压缩（接近阈值）；75% 通常压缩
    case "$RATIO" in
        0|25)
            if [ "$STATE" -eq 0 ]; then
                pass "可压缩率 ${RATIO}% 文件保持 RAW（size ${BEFORE_SIZE} -> ${AFTER_SIZE}）"
            else
                fail "可压缩率 ${RATIO}% 文件被错误压缩为 state=${STATE}"
            fi
            ;;
        50)
            # 50% 是边界，记录结果即可
            if [ "$STATE" -eq 0 ]; then
                pass "可压缩率 50% 文件保持 RAW（接近阈值）"
            else
                echo "  可压缩率 50% 文件被压缩为 state=${STATE}（符合阈值策略）"
                pass "可压缩率 50% 文件处理结果可接受"
            fi
            ;;
        100)
            if [ "$STATE" -eq 1 ]; then
                pass "可压缩率 100% 文件被正确压缩"
            else
                fail "可压缩率 100% 文件未被压缩（state=${STATE}）"
            fi
            ;;
    esac
done

echo ""
echo "========================================"
echo "       汇总"
echo "========================================"
echo -e "${GREEN}PASS: $PASS${NC}"
echo -e "${RED}FAIL: $FAIL${NC}"

rm -rf "$TESTDIR"
[ $FAIL -eq 0 ]
