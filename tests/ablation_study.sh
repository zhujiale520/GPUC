#!/bin/bash
set -e

# ============================================================
#  Ablation Study — 消融实验一键脚本
#
#  逐项关闭优化，量化每项对顺序读带宽的贡献
#  固定条件：512MB zero 数据，128k bs，sync 引擎，page cache 命中
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_ablation_$$"
RESULTDIR="/tmp/gpuc_ablation_results_$$"
mkdir -p "$TESTDIR" "$RESULTDIR"

RUNTIME=10
SIZE="512M"
BS="128k"
TESTFILE="$TESTDIR/ablation.bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/ablation.csv"
echo "scenario,flags,bw_mb_s" > "$RESULT_CSV"

# ----------------------------------------------------------
#  辅助函数
# ----------------------------------------------------------
build_hook() {
    local flags=$1
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" ABLATION_FLAGS="$flags" bin/libgpuhook.so >/dev/null 2>&1
}

run_fio_read() {
    local scenario=$1
    local flags=$2
    local label=$3

    echo ""
    echo -e "${BLUE}>>> ${label}${NC}"
    build_hook "$flags"

    # 预热：先读取一次让 page cache 命中
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name=warmup --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
            --rw=read --runtime=3 --time_based --direct=0 --ioengine=sync \
            >/dev/null 2>&1 || true

    # 正式测试
    local json_out="$RESULTDIR/${scenario}.json"
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name="$scenario" --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
            --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
            --output-format=json > "$json_out" 2>/dev/null

    local bw=$(python3 -c "
import json,sys
data=json.load(open('$json_out'))
print(data['jobs'][0]['read']['bw']/1024)
" 2>/dev/null || echo "0")

    echo -e "  Bandwidth: ${GREEN}${bw} MB/s${NC}"
    echo "$scenario,$flags,$bw" >> "$RESULT_CSV"
}

# ----------------------------------------------------------
#  前置准备：创建测试文件并压缩
# ----------------------------------------------------------
echo "========================================"
echo "  Ablation Study — 消融实验"
echo "========================================"
echo "测试文件: $TESTFILE"
echo "大小: $SIZE, 块大小: $BS, 运行时间: ${RUNTIME}s"
echo ""

# 1. 写入 RAW 文件
echo "[SETUP] 创建测试文件..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    fio --name=write --filename="$TESTFILE" --size="$SIZE" --bs="$BS" \
        --rw=write --buffer_pattern=0x00 --direct=0 --ioengine=sync >/dev/null 2>&1

# 2. 用 Daemon GPU 压缩
echo "[SETUP] Daemon GPU 压缩..."
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

# 验证压缩状态
python3 << EOF
import struct
with open('$TESTFILE', 'rb') as f:
    magic = struct.unpack('<I', f.read(4))[0]
    state = struct.unpack('<B', f.read(1))[0] if magic == 0x47505543 else None
    print(f"[SETUP] File state: {'COMPRESSED' if state == 1 else 'RAW' if state == 0 else 'UNKNOWN'} (state={state})")
EOF

# ----------------------------------------------------------
#  消融实验组
# ----------------------------------------------------------
run_fio_read "baseline"    ""                    "A: 全优化基线"
run_fio_read "no_ioring"   "-DGPUC_NO_IOURING"   "B: 关闭 io_uring"
run_fio_read "no_readahead" "-DGPUC_NO_READAHEAD" "C: 关闭 Read-Ahead"
run_fio_read "no_pipeline" "-DGPUC_NO_PIPELINE"  "D: 关闭双缓冲流水线"
run_fio_read "no_pinned"   "-DGPUC_NO_PINNED"    "E: 关闭 Pinned Memory"
run_fio_read "no_batch"    "-DGPUC_NO_BATCH"     "H: 关闭 Batch Decompress (逐块)"
run_fio_read "minimal"     "-DGPUC_NO_BATCH -DGPUC_NO_PIPELINE -DGPUC_NO_READAHEAD -DGPUC_NO_IOURING -DGPUC_NO_PINNED" \
                           "MIN: 全部关闭（最简路径）"

# ----------------------------------------------------------
#  汇总输出
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "  Ablation Study 结果汇总"
echo "========================================"
python3 << EOF
import csv, sys
rows = list(csv.DictReader(open('$RESULT_CSV')))
if len(rows) < 2:
    print("数据不足")
    sys.exit(0)

base_bw = float(rows[0]['bw_mb_s'])
print(f"{'场景':<20} {'带宽(MB/s)':>12} {'降幅':>10}")
print("-" * 45)
for r in rows:
    bw = float(r['bw_mb_s'])
    drop = (base_bw - bw) / base_bw * 100 if base_bw > 0 else 0
    print(f"{r['scenario']:<20} {bw:>12.1f} {drop:>9.1f}%")
EOF

echo ""
echo -e "${GREEN}原始数据已保存到: $RESULTDIR/ablation.csv${NC}"
