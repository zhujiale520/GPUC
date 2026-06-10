#!/bin/bash
set -e

# ============================================================
#  Power Efficiency — GPU 解压功耗与能效测试
#
#  测量指标：
#    - 持续读取 512MB 压缩文件时的 GPU 平均功耗
#    - 能效 = 功耗(W) / 带宽(GB/s)
#  注意：当前环境无 turbostat/rapl，无法精确测量 CPU 功耗，
#        因此仅给出 GPU 路径的能效数据作为参考。
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_power_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/power.bin"
RUNTIME=30
BS="128k"
SIZE="512M"

BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m'

# 确保编译产物
if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

# 创建并压缩测试文件
echo "[SETUP] Creating test file..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

echo ""
echo "========================================"
echo "  GPU Power Efficiency Test"
echo "========================================"

# 后台采样 GPU 功耗，1Hz
POWER_LOG="$TESTDIR/power.log"
nvidia-smi --query-gpu=timestamp,power.draw --format=csv,noheader -l 1 > "$POWER_LOG" 2>/dev/null &
NV_PID=$!

# 运行 fio
JSON_OUT="$TESTDIR/fio.json"
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name="gpu_read" --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
        --output-format=json > "$JSON_OUT" 2>/dev/null

# 停止采样
kill $NV_PID 2>/dev/null || true
wait $NV_PID 2>/dev/null || true

# 解析结果
BW=$(python3 -c "
import json
with open('$JSON_OUT') as f:
    d = json.load(f)
print(f\"{d['jobs'][0]['read']['bw']/1024:.1f}\")
")

AVG_POWER=$(python3 -c "
import re
total = 0.0
count = 0
with open('$POWER_LOG') as f:
    for line in f:
        m = re.search(r'(\d+\.?\d*)\s*W', line)
        if m:
            total += float(m.group(1))
            count += 1
print(f\"{total/max(count,1):.2f}\" if count > 0 else \"0\")
")

EFFICIENCY=$(echo "scale=3; $AVG_POWER / ($BW / 1024)" | bc)

echo ""
echo -e "${BLUE}>>> GPU 解压路径${NC}"
echo "  Read bandwidth: ${GREEN}${BW} MB/s${NC}"
echo "  Average GPU power: ${GREEN}${AVG_POWER} W${NC}"
echo "  Power efficiency: ${GREEN}${EFFICIENCY} W/GB${NC}"

echo ""
echo "========================================"
echo "  Power Efficiency Summary"
echo "========================================"
printf "${GREEN}%-20s %15s %15s %15s${NC}\n" "Backend" "BW(MB/s)" "Power(W)" "W/GB"
echo "---------------------------------------------------------------"
printf "%-20s %15s %15s %15s\n" "GPU decompress" "$BW" "$AVG_POWER" "$EFFICIENCY"
printf "%-20s %15s %15s %15s\n" "CPU decompress" "—" "—" "N/A¹"
echo ""
echo "¹ 当前环境缺少 turbostat/rapl，无法精确测量 CPU 功耗。"

rm -rf "$TESTDIR"
