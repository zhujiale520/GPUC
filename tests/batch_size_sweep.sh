#!/bin/bash
set -e

# ============================================================
#  Batch Size 扫描 — 验证 16 blocks 是 sweet spot
#
#  固定条件：512MB zero 数据，128k bs，sync 引擎，page cache 命中
#  变量：MAX_BATCH_BLOCKS = 1, 2, 4, 8, 16, 32
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_batchsweep_$$"
RESULTDIR="/tmp/gpuc_batchsweep_results_$$"
mkdir -p "$TESTDIR" "$RESULTDIR"

# 确保 daemon 已编译（只需一次）
if [ ! -f "$PROJECT_DIR/bin/gpu_compress_daemon" ]; then
    make -C "$PROJECT_DIR" bin/gpu_compress_daemon >/dev/null 2>&1
fi

RUNTIME=10
SIZE="512M"
BS="128k"
TESTFILE="$TESTDIR/sweep.bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/batch_size.csv"
echo "batch_size,bw_mb_s" > "$RESULT_CSV"

# ----------------------------------------------------------
#  前置准备：创建测试文件并压缩
# ----------------------------------------------------------
echo "========================================"
echo "  Batch Size 性能扫描"
echo "========================================"
echo "测试文件: $TESTFILE"
echo "大小: $SIZE, 块大小: $BS, 运行时间: ${RUNTIME}s"
echo ""

echo "[SETUP] 创建测试文件..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1

echo "[SETUP] Daemon GPU 压缩..."
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

python3 << EOF
import struct
with open('$TESTFILE', 'rb') as f:
    magic = struct.unpack('<I', f.read(4))[0]
    state = struct.unpack('<B', f.read(1))[0] if magic == 0x47505543 else None
    print(f"[SETUP] File state: {'COMPRESSED' if state == 1 else 'RAW' if state == 0 else 'UNKNOWN'} (state={state})")
EOF

# ----------------------------------------------------------
#  扫描不同 batch size
# ----------------------------------------------------------
for BATCH in 1 2 4 8 16 32; do
    echo ""
    echo -e "${BLUE}>>> MAX_BATCH_BLOCKS = ${BATCH}${NC}"

    rm -f "$PROJECT_DIR/bin/libgpuhook.so"
    make -C "$PROJECT_DIR" ABLATION_FLAGS="-DMAX_BATCH_BLOCKS=${BATCH}" bin/libgpuhook.so >/dev/null 2>&1

    # 预热
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name=warmup --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
            --rw=read --runtime=3 --time_based --direct=0 --ioengine=sync \
            >/dev/null 2>&1 || true

    # 正式测试
    json_out="$RESULTDIR/batch_${BATCH}.json"
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name="batch_${BATCH}" --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
            --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
            --output-format=json > "$json_out" 2>/dev/null

    bw=$(python3 -c "
import json,sys
data=json.load(open('$json_out'))
print(data['jobs'][0]['read']['bw']/1024)
" 2>/dev/null || echo "0")

    echo -e "  Bandwidth: ${GREEN}${bw} MB/s${NC}"
    echo "$BATCH,$bw" >> "$RESULT_CSV"
done

# ----------------------------------------------------------
#  汇总输出
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "  Batch Size 扫描结果"
echo "========================================"
python3 << EOF
import csv
rows = list(csv.DictReader(open('$RESULT_CSV')))
print(f"{'Batch Size':<12} {'带宽(MB/s)':>12}")
print("-" * 25)
for r in rows:
    print(f"{r['batch_size']:<12} {float(r['bw_mb_s']):>12.1f}")
EOF

echo ""
echo -e "${GREEN}原始数据已保存到: $RESULTDIR/batch_size.csv${NC}"
