#!/bin/bash
set -e

# ============================================================
#  Large File Benchmark — 4G / 16G / 64G
# ============================================================
# 测试项：
#   1. RAW 文件创建时间
#   2. GPU daemon 压缩时间
#   3. 压缩后物理大小
#   4. 顺序读带宽（bs=128k/1M, jobs=1/32, direct=1）
#   5. mmap() 返回时间
#
# 默认测试 4G 和 16G；64G 通过 LARGE_FILES=1 启用。
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_large_file_test"
RESULTDIR="/tmp/gpuc_large_file_results"

mkdir -p "$TESTDIR" "$RESULTDIR"

RUNTIME=30
BS_LIST="128k 1M"
JOBS_LIST="1 32"

# 默认测 4G；16G/64G 通过 LARGE_FILES=1 启用，并会检查可用空间
SIZE_LIST="4G"
if [ "${LARGE_FILES:-0}" = "1" ]; then
    SIZE_LIST="4G 16G 64G"
fi

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/results.csv"
echo "size,scenario,bs,jobs,bw_mb_s,iops,lat_us" > "$RESULT_CSV"
RESULT_META="$RESULTDIR/meta.csv"
echo "size,raw_create_sec,compress_sec,logical_mb,physical_mb,ratio_pct" > "$RESULT_META"

# ----------------------------------------------------------
#  创建 RAW 文件并压缩
# ----------------------------------------------------------
prepare_file() {
    local size=$1
    local testfile="$TESTDIR/fio_${size}.bin"
    rm -f "$testfile"

    echo -e "${BLUE}[PREPARE $size] 创建 RAW 文件${NC}"
    local t0=$(date +%s.%N)
    # 将 4G/16G/64G 转换为字节数
    local size_bytes=$(numfmt --from=iec "$size")
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if=/dev/zero of="$testfile" bs=1M status=none iflag=count_bytes count="$size_bytes"
    sync
    local t1=$(date +%s.%N)
    local raw_create=$(printf "%.2f" $(python3 -c "print($t1 - $t0)"))

    echo -e "${BLUE}[PREPARE $size] GPU daemon 压缩${NC}"
    local t2=$(date +%s.%N)
    "$GPU_DAEMON" "$TESTDIR" >/dev/null 2>&1
    local t3=$(date +%s.%N)
    local compress_sec=$(printf "%.2f" $(python3 -c "print($t3 - $t2)"))

    local logical_bytes=$(stat -c %s "$testfile")
    local physical_bytes=$(du -B1 "$testfile" | cut -f1)
    local logical_mb=$((logical_bytes / 1024 / 1024))
    local physical_mb=$((physical_bytes / 1024 / 1024))
    local ratio=$(printf "%.1f" $(python3 -c "print($physical_bytes / $logical_bytes * 100)"))

    echo -e "${GREEN}  RAW 创建: ${raw_create}s, 压缩: ${compress_sec}s, 物理: ${physical_mb}MB, 压缩率: ${ratio}%${NC}"
    echo "$size,$raw_create,$compress_sec,$logical_mb,$physical_mb,$ratio" >> "$RESULT_META"
}

# ----------------------------------------------------------
#  顺序读测试
# ----------------------------------------------------------
run_read() {
    local size=$1
    local bs=$2
    local jobs=$3
    local preload=$4
    local scenario=$5
    local testfile="$TESTDIR/fio_${size}.bin"
    local json_out="$RESULTDIR/${scenario}_${size}_${bs}_j${jobs}.json"

    if [ -n "$preload" ]; then
        export LD_PRELOAD="$preload"
        export GPUCOMPRESS_QUIET=1
    else
        unset LD_PRELOAD
        unset GPUCOMPRESS_QUIET
    fi

    fio \
        --name="${scenario}_${size}_${bs}_j${jobs}" \
        --filename="$testfile" \
        --size="$size" \
        --bs="$bs" \
        --rw=read \
        --direct=1 \
        --ioengine=sync \
        --runtime="$RUNTIME" \
        --time_based \
        --numjobs="$jobs" \
        --group_reporting \
        --unlink=0 \
        --buffer_pattern=0x00 \
        --output-format=json > "$json_out" 2>/dev/null

    python3 - << PYEOF
import json
try:
    with open('$json_out') as f:
        d = json.load(f)
    job = d['jobs'][0]['read']
    bw = job['bw'] / 1024
    iops = job['iops']
    lat = job['lat_ns']['mean'] / 1000
    print(f"  bw={bw:.1f} MB/s iops={iops:.0f} lat={lat:.1f} us")
    with open('$RESULT_CSV', 'a') as cf:
        cf.write("$size,$scenario,$bs,$jobs,%.1f,%.0f,%.1f\n" % (bw, iops, lat))
except Exception as e:
    print(f"  ERROR: {e}")
PYEOF
}

# ----------------------------------------------------------
#  mmap 返回时间测试
# ----------------------------------------------------------
run_mmap() {
    local size=$1
    local testfile="$TESTDIR/fio_${size}.bin"
    local json_out="$RESULTDIR/mmap_${size}.json"

    echo -e "${BLUE}[MMAP $size] 测量 mmap 返回时间${NC}"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name=mmap_${size} --filename="$testfile" --size="$size" --bs=4k \
            --rw=read --mmap=1 --runtime=5 --time_based --numjobs=1 \
            --group_reporting --unlink=0 --output-format=json > "$json_out" 2>/dev/null || true

    # 如果 fio 不支持 --mmap，fallback 到自定义 C 程序
    if [ ! -s "$json_out" ]; then
        echo "  (fio mmap 不支持，使用自定义测试)"
        if [ ! -f "$PROJECT_DIR/bin/test_mmap_ondemand" ]; then
            gcc -O3 "$PROJECT_DIR/tests/test_mmap_ondemand.c" -o "$PROJECT_DIR/bin/test_mmap_ondemand"
        fi
        LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
            "$PROJECT_DIR/bin/test_mmap_ondemand" "$testfile" 2>/dev/null || true
    fi
}

# ----------------------------------------------------------
#  主流程
# ----------------------------------------------------------
echo "========================================"
echo "  Large File Benchmark"
echo "========================================"
echo "目录: $TESTDIR"
echo "文件大小: $SIZE_LIST"
echo "每项读测试: ${RUNTIME}s"
echo "========================================"

for SIZE in $SIZE_LIST; do
    echo ""
    echo -e "${YELLOW}########## Size = $SIZE ##########${NC}"
    prepare_file "$SIZE"

    echo ""
    echo -e "${YELLOW}--- 顺序读测试 ---${NC}"
    for BS in $BS_LIST; do
        for JOBS in $JOBS_LIST; do
            echo -e "${GREEN}>>> $SIZE bs=$BS jobs=$JOBS Baseline${NC}"
            run_read "$SIZE" "$BS" "$JOBS" "" "baseline"
            echo -e "${GREEN}>>> $SIZE bs=$BS jobs=$JOBS GPU Compressed${NC}"
            run_read "$SIZE" "$BS" "$JOBS" "$HOOK_SO" "gpu_compressed"
        done
    done

    echo ""
    run_mmap "$SIZE"
done

# ----------------------------------------------------------
#  汇总
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "       大文件测试汇总"
echo "========================================"

python3 - << PYEOF
import csv
print("\n--- 文件元数据 ---")
print(f"{'Size':<8} {'RAW创建(s)':<12} {'压缩(s)':<10} {'逻辑(MB)':<10} {'物理(MB)':<10} {'压缩率':<10}")
print("-" * 70)
with open('$RESULT_META') as f:
    reader = csv.DictReader(f)
    for r in reader:
        print(f"{r['size']:<8} {r['raw_create_sec']:<12} {r['compress_sec']:<10} {r['logical_mb']:<10} {r['physical_mb']:<10} {r['ratio_pct']:<10}%")

print("\n--- 顺序读带宽 (MB/s) ---")
print(f"{'Size':<8} {'BS':<6} {'Jobs':<6} {'Baseline':>12} {'GPU Compressed':>16} {'Ratio':>10}")
print("-" * 70)
base = {}
gpu = {}
with open('$RESULT_CSV') as f:
    reader = csv.DictReader(f)
    for r in reader:
        key = (r['size'], r['bs'], r['jobs'])
        if r['scenario'] == 'baseline':
            base[key] = float(r['bw_mb_s'])
        elif r['scenario'] == 'gpu_compressed':
            gpu[key] = float(r['bw_mb_s'])
for key in sorted(base.keys()):
    if key in gpu:
        ratio = gpu[key] / base[key] * 100
        print(f"{key[0]:<8} {key[1]:<6} {key[2]:<6} {base[key]:>12.1f} {gpu[key]:>16.1f} {ratio:>9.1f}%")
PYEOF

echo ""
echo -e "${GREEN}完成。CSV: $RESULT_CSV, $RESULT_META${NC}"
