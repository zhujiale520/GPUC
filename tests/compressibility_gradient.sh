#!/bin/bash
set -e

# ============================================================
#  Compressibility Gradient Benchmark
# ============================================================
# 生成 0% / 25% / 50% / 75% / 100% 可压缩率数据，
# 测试压缩率、压缩耗时、解压读带宽的关系。
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_compressibility_$$"
RESULTDIR="/tmp/gpuc_compressibility_results_$$"

mkdir -p "$TESTDIR" "$RESULTDIR"

SIZE="512M"
SIZE_BYTES=$(numfmt --from=iec "$SIZE")
RUNTIME=15

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/results.csv"
echo "compressibility,logical_mb,raw_create_sec,compress_sec,physical_mb,ratio_pct,bw_mb_s" > "$RESULT_CSV"

# ----------------------------------------------------------
#  生成指定可压缩率的文件
#  ratio: 0, 25, 50, 75, 100
# ----------------------------------------------------------
generate_file() {
    local ratio=$1
    local outfile=$2
    local bs=4096
    local total=$SIZE_BYTES
    local random_bytes=$((bs * (100 - ratio) / 100))
    local zero_bytes=$((bs - random_bytes))

    echo -e "${BLUE}生成可压缩率 ${ratio}% 文件...${NC}"
    rm -f "$outfile"

    # 使用 Python 生成混合数据，保证每 4KB 块内可压缩率精确
    python3 - << PYEOF
import os
bs = $bs
total = $total
random_bytes = $random_bytes
zero_bytes = $zero_bytes
pattern = os.urandom(random_bytes) + b'\x00' * zero_bytes
# 重复 pattern 直到 total（pattern 本身长度是 bs）
with open('$outfile', 'wb') as f:
    written = 0
    while written < total:
        chunk = pattern[:min(bs, total - written)]
        f.write(chunk)
        written += len(chunk)
PYEOF
}

# ----------------------------------------------------------
#  运行测试
# ----------------------------------------------------------
run_test() {
    local ratio=$1
    local infile="$TESTDIR/data_${ratio}pct.bin"
    local testfile="$TESTDIR/fio_${ratio}pct.bin"
    local json_out="$RESULTDIR/fio_${ratio}pct.json"

    # 生成输入文件
    generate_file "$ratio" "$infile"

    # 用 hook 创建 RAW 文件
    echo -e "${BLUE}[$ratio%] 创建 RAW 文件${NC}"
    local t0=$(date +%s.%N)
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 cp "$infile" "$testfile"
    sync
    local t1=$(date +%s.%N)
    local raw_create=$(printf "%.2f" $(python3 -c "print($t1 - $t0)"))

    # daemon 压缩
    echo -e "${BLUE}[$ratio%] GPU daemon 压缩${NC}"
    local t2=$(date +%s.%N)
    "$GPU_DAEMON" "$TESTDIR" >/dev/null 2>&1
    local t3=$(date +%s.%N)
    local compress_sec=$(printf "%.2f" $(python3 -c "print($t3 - $t2)"))

    local logical_bytes=$(stat -c %s "$testfile")
    local physical_bytes=$(du -B1 "$testfile" | cut -f1)
    local logical_mb=$((logical_bytes / 1024 / 1024))
    local physical_mb=$((physical_bytes / 1024 / 1024))
    local ratio_pct=$(printf "%.1f" $(python3 -c "print($physical_bytes / $logical_bytes * 100)"))

    echo -e "${GREEN}  RAW创建: ${raw_create}s, 压缩: ${compress_sec}s, 物理: ${physical_mb}MB, 压缩率: ${ratio_pct}%${NC}"

    # 顺序读解压带宽
    echo -e "${BLUE}[$ratio%] 顺序读解压带宽${NC}"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name="grad_${ratio}" --filename="$testfile" --size="$SIZE" --bs=128k \
            --rw=read --direct=1 --ioengine=sync --runtime="$RUNTIME" --time_based --numjobs=1 \
            --group_reporting --unlink=0 --output-format=json > "$json_out" 2>/dev/null

    python3 - << PYEOF
import json
with open('$json_out') as f:
    d = json.load(f)
bw = d['jobs'][0]['read']['bw'] / 1024
print(f"  bw={bw:.1f} MB/s")
with open('$RESULT_CSV', 'a') as cf:
    cf.write("$ratio,$logical_mb,$raw_create,$compress_sec,$physical_mb,$ratio_pct,%.1f\n" % bw)
PYEOF
}

# ----------------------------------------------------------
#  主流程
# ----------------------------------------------------------
echo "========================================"
echo "  Compressibility Gradient Benchmark"
echo "========================================"
echo "目录: $TESTDIR"
echo "大小: $SIZE"
echo "========================================"

for RATIO in 0 25 50 75 100; do
    echo ""
    echo -e "${YELLOW}########## 可压缩率 = ${RATIO}% ##########${NC}"
    run_test "$RATIO"
done

# ----------------------------------------------------------
#  汇总
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "       可压缩率梯度汇总"
echo "========================================"
python3 - << PYEOF
import csv
rows = []
with open('$RESULT_CSV') as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

print(f"{'可压缩率':<10} {'逻辑(MB)':<10} {'RAW创建(s)':<12} {'压缩(s)':<10} {'物理(MB)':<10} {'压缩率%':<10} {'读带宽(MB/s)':<15}")
print("-" * 90)
for r in rows:
    print(f"{r['compressibility']:<10} {r['logical_mb']:<10} {r['raw_create_sec']:<12} {r['compress_sec']:<10} {r['physical_mb']:<10} {r['ratio_pct']:<10} {r['bw_mb_s']:<15}")

print("\n--- 关键结论 ---")
print("随着可压缩率提升，物理大小和压缩时间应下降；解压读带宽与压缩率关系可观察拐点。")
PYEOF

rm -rf "$TESTDIR"
echo ""
echo -e "${GREEN}完成。CSV: $RESULT_CSV${NC}"
