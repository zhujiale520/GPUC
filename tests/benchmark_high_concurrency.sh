#!/bin/bash
set -e

# ============================================================
#  GPU Compress - 高并发性能基准测试 (jobs=32 优化验证)
# ============================================================
# 测试维度：
#   1. 并发度：1, 4, 8, 16, 32
#   2. I/O 大小：128k, 1M
#   3. direct 模式：0 (buffered), 1 (O_DIRECT)
#   4. 数据模式：zero (高压缩率), rand (不可压缩)
#   5. 对比：Baseline vs GPU Hook (压缩后读取)
#
# 关键修正：
#   - 使用 LD_PRELOAD=libgpuhook.so 创建 RAW 文件，确保 header 正确
#   - 再用 gpu_compress_daemon 压缩，保证读取时真正走 GPU 解压路径
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_high_concurrency_test"
RESULTDIR="/tmp/gpuc_high_concurrency_results"

mkdir -p "$TESTDIR" "$RESULTDIR"

SIZE="512M"
RUNTIME=10
BS_LIST="128k 1M"
JOBS_LIST="1 4 8 16 32"
DIRECT_LIST="0 1"

# 快速模式：仅测 jobs=1/32 + direct=1
if [ "${GPUC_QUICK:-0}" = "1" ]; then
    JOBS_LIST="1 32"
    DIRECT_LIST="1"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/results.csv"
echo "pattern,bs,direct,jobs,scenario,bw_mb_s,iops,lat_us" > "$RESULT_CSV"

# ----------------------------------------------------------
#  运行 fio 测试
#  参数: tag pattern bs direct jobs preload
# ----------------------------------------------------------
run_fio() {
    local tag=$1
    local pattern=$2
    local bs=$3
    local direct=$4
    local jobs=$5
    local preload=$6
    local testfile="$TESTDIR/fio_${pattern}_${bs}.bin"
    local json_out="$RESULTDIR/${tag}.json"

    if [ -n "$preload" ]; then
        export LD_PRELOAD="$preload"
        export GPUCOMPRESS_QUIET=1
    else
        unset LD_PRELOAD
        unset GPUCOMPRESS_QUIET
    fi

    local extra_opts=""
    if [ "$pattern" = "zero" ]; then
        extra_opts="--buffer_pattern=0x00"
    else
        extra_opts="--buffer_pattern=0xDEADBEEF"
    fi

    fio \
        --name="$tag" \
        --filename="$testfile" \
        --size="$SIZE" \
        --bs="$bs" \
        --rw=read \
        --direct="$direct" \
        --ioengine=sync \
        --runtime="$RUNTIME" \
        --time_based \
        --numjobs="$jobs" \
        --group_reporting \
        --unlink=0 \
        $extra_opts \
        --output-format=json > "$json_out" 2>/dev/null

    python3 - << PYEOF
import json, os, sys
try:
    with open('$json_out') as f:
        d = json.load(f)
    job = d['jobs'][0]
    bw = job['read']['bw'] / 1024
    iops = job['read']['iops']
    lat = job['read']['lat_ns']['mean'] / 1000
    print(f"  bw={bw:.1f} MB/s iops={iops:.0f} lat={lat:.1f} us")
    with open('$RESULT_CSV', 'a') as cf:
        cf.write("$pattern,$bs,$direct,$jobs,$scenario,%.1f,%.0f,%.1f\n" % (bw, iops, lat))
except Exception as e:
    print(f"  ERROR: {e}")
PYEOF
}

# ----------------------------------------------------------
#  创建并压缩测试文件
# ----------------------------------------------------------
prepare_file() {
    local pattern=$1
    local bs=$2
    local testfile="$TESTDIR/fio_${pattern}_${bs}.bin"
    rm -f "$testfile"

    echo -e "${BLUE}[PREPARE] 创建 RAW 文件 ($pattern/$bs)${NC}"
    if [ "$pattern" = "zero" ]; then
        LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if=/dev/zero of="$testfile" bs=1M count=512 status=none
    else
        LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if=/dev/urandom of="$testfile" bs=1M count=512 status=none
    fi

    echo -e "${BLUE}[PREPARE] GPU daemon 压缩 ($pattern/$bs)${NC}"
    "$GPU_DAEMON" "$TESTDIR" >/dev/null 2>&1

    local phys_size=$(stat -c %s "$testfile" 2>/dev/null || echo 0)
    echo -e "${BLUE}[PREPARE] 物理大小: $((phys_size / 1024 / 1024)) MB${NC}"
}

# ----------------------------------------------------------
#  主流程
# ----------------------------------------------------------
echo "========================================"
echo "  GPU Compress - 高并发性能基准测试"
echo "========================================"
echo "测试目录: $TESTDIR"
echo "文件大小: $SIZE"
echo "运行时间: ${RUNTIME}s / 每项"
echo "并发列表: $JOBS_LIST"
echo "I/O 大小: $BS_LIST"
echo "========================================"

for PATTERN in zero rand; do
    for BS in $BS_LIST; do
        echo ""
        echo -e "${YELLOW}########## Pattern=$PATTERN BS=$BS ##########${NC}"
        prepare_file "$PATTERN" "$BS"

        for DIRECT in $DIRECT_LIST; do
            echo ""
            echo -e "${YELLOW}------ direct=$DIRECT ------${NC}"

            for JOBS in $JOBS_LIST; do
                echo ""
                echo -e "${GREEN}>>> jobs=$JOBS Baseline${NC}"
                scenario="baseline"
                run_fio "baseline_${PATTERN}_${BS}_d${DIRECT}_j${JOBS}" "$PATTERN" "$BS" "$DIRECT" "$JOBS" ""

                echo -e "${GREEN}>>> jobs=$JOBS GPU Hook (compressed)${NC}"
                scenario="gpu_hook"
                run_fio "gpu_${PATTERN}_${BS}_d${DIRECT}_j${JOBS}" "$PATTERN" "$BS" "$DIRECT" "$JOBS" "$HOOK_SO"
            done
        done
    done
done

# ----------------------------------------------------------
#  汇总报告
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "       高并发性能汇总报告"
echo "========================================"
python3 - << PYEOF
import csv, os
rows = []
with open('$RESULT_CSV') as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

print(f"{'Pattern':<8} {'BS':<6} {'Direct':<7} {'Jobs':<6} {'Scenario':<12} {'BW(MB/s)':>10} {'IOPS':>8} {'Latency(us)':>12}")
print("-" * 90)
for r in rows:
    print(f"{r['pattern']:<8} {r['bs']:<6} {r['direct']:<7} {r['jobs']:<6} {r['scenario']:<12} {float(r['bw_mb_s']):>10.1f} {float(r['iops']):>8.0f} {float(r['lat_us']):>12.1f}")

print("\n--- GPU Hook vs Baseline 比例 (%) ---")
from collections import defaultdict
base = {}
gpu = {}
for r in rows:
    key = (r['pattern'], r['bs'], r['direct'], r['jobs'])
    if r['scenario'] == 'baseline':
        base[key] = float(r['bw_mb_s'])
    elif r['scenario'] == 'gpu_hook':
        gpu[key] = float(r['bw_mb_s'])

for key in sorted(base.keys()):
    if key in gpu:
        ratio = gpu[key] / base[key] * 100
        print(f"  {key}: {ratio:.1f}%")
PYEOF

echo ""
echo -e "${GREEN}全部测试完成！${NC}"
echo "CSV 结果: $RESULT_CSV"
echo "JSON 原始数据: $RESULTDIR/*.json"
