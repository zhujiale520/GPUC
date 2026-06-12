#!/bin/bash
set -e

# ============================================================
#  Write Path & Mixed Workload Benchmark
# ============================================================
# 测试维度：
#   1. 多线程并发写（jobs=1/4/8/16/32）
#   2. 随机读写混合（randrw，rwmixread=70/50/30）
#   3. 顺序读写混合（rw，rwmixread=50）
#   4. 写后立刻读（fresh data path）
#   5. 对比：Baseline / Hook RAW / GPU Compressed
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_write_mixed_$$"
RESULTDIR="/tmp/gpuc_write_mixed_results_$$"

mkdir -p "$TESTDIR" "$RESULTDIR"

SIZE="512M"
RUNTIME=10
JOBS_LIST="1 4 8 16 32"
BS_LIST="128k 1M"

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/results.csv"
echo "scenario,bs,jobs,rw,rwmixread,bw_mb_s,iops,lat_us" > "$RESULT_CSV"

# ----------------------------------------------------------
#  运行 fio 并解析结果
#  参数: tag bs jobs rw rwmixread preload [extra_opts]
# ----------------------------------------------------------
run_fio() {
    local tag=$1
    local bs=$2
    local jobs=$3
    local rw=$4
    local rwmixread=$5
    local preload=$6
    local testfile="$TESTDIR/fio_${bs}.bin"
    local json_out="$RESULTDIR/${tag}.json"

    if [ -n "$preload" ]; then
        export LD_PRELOAD="$preload"
        export GPUCOMPRESS_QUIET=1
    else
        unset LD_PRELOAD
        unset GPUCOMPRESS_QUIET
    fi

    local mix_opt=""
    if [ -n "$rwmixread" ]; then
        mix_opt="--rwmixread=$rwmixread"
    fi

    fio \
        --name="$tag" \
        --filename="$testfile" \
        --size="$SIZE" \
        --bs="$bs" \
        --rw="$rw" \
        --direct=1 \
        --ioengine=sync \
        --runtime="$RUNTIME" \
        --time_based \
        --numjobs="$jobs" \
        --group_reporting \
        --unlink=1 \
        $mix_opt \
        --output-format=json > "$json_out" 2>/dev/null

    python3 - << PYEOF
import json
try:
    with open('$json_out') as f:
        d = json.load(f)
    job = d['jobs'][0]
    if '$rw' in ('read', 'randread'):
        bw = job['read']['bw'] / 1024
        iops = job['read']['iops']
        lat = job['read']['lat_ns']['mean'] / 1000
    elif '$rw' in ('write', 'randwrite'):
        bw = job['write']['bw'] / 1024
        iops = job['write']['iops']
        lat = job['write']['lat_ns']['mean'] / 1000
    else:
        rbw = job['read']['bw'] / 1024
        riops = job['read']['iops']
        rlat = job['read']['lat_ns']['mean'] / 1000
        wbw = job['write']['bw'] / 1024
        wiops = job['write']['iops']
        wlat = job['write']['lat_ns']['mean'] / 1000
        bw = rbw + wbw
        iops = riops + wiops
        lat = (rlat + wlat) / 2
    print(f"  bw={bw:.1f} MB/s iops={iops:.0f} lat={lat:.1f} us")
    with open('$RESULT_CSV', 'a') as cf:
        cf.write("$scenario,$bs,$jobs,$rw,$rwmixread,%.1f,%.0f,%.1f\n" % (bw, iops, lat))
except Exception as e:
    print(f"  ERROR: {e}")
PYEOF
}

# ----------------------------------------------------------
#  主流程
# ----------------------------------------------------------
echo "========================================"
echo "  Write Path & Mixed Workload"
echo "========================================"
echo "目录: $TESTDIR"
echo "大小: $SIZE"
echo "时间: ${RUNTIME}s / 项"
echo "========================================"

# 1. 多线程并发写
for BS in $BS_LIST; do
    echo ""
    echo -e "${YELLOW}### 并发写测试 bs=$BS ###${NC}"
    for JOBS in $JOBS_LIST; do
        echo -e "${GREEN}>>> jobs=$JOBS Baseline${NC}"
        scenario="baseline_write"
        run_fio "baseline_write_${BS}_j${JOBS}" "$BS" "$JOBS" "write" "" ""

        echo -e "${GREEN}>>> jobs=$JOBS Hook RAW${NC}"
        scenario="hook_raw_write"
        run_fio "hook_raw_write_${BS}_j${JOBS}" "$BS" "$JOBS" "write" "" "$HOOK_SO"
    done
done

# 2. 混合读写（randrw，多种 mix 比例）
for BS in $BS_LIST; do
    echo ""
    echo -e "${YELLOW}### 随机读写混合 bs=$BS ###${NC}"
    for MIX in 70 50 30; do
        for JOBS in 1 32; do
            echo -e "${BLUE}>>> mixread=$MIX jobs=$JOBS Baseline${NC}"
            scenario="baseline_randrw"
            run_fio "baseline_randrw_${MIX}_${BS}_j${JOBS}" "$BS" "$JOBS" "randrw" "$MIX" ""

            echo -e "${BLUE}>>> mixread=$MIX jobs=$JOBS Hook RAW${NC}"
            scenario="hook_raw_randrw"
            run_fio "hook_raw_randrw_${MIX}_${BS}_j${JOBS}" "$BS" "$JOBS" "randrw" "$MIX" "$HOOK_SO"
        done
    done
done

# 3. 写后立刻读（fresh data）
echo ""
echo -e "${YELLOW}### 写后立刻读（fresh data path）###${NC}"
FRESH_FILE="$TESTDIR/fresh_data.bin"
for BS in $BS_LIST; do
    # Baseline
    rm -f "$FRESH_FILE"
    dd if=/dev/zero of="$FRESH_FILE" bs=1M count=512 status=none
    sync
    echo -e "${GREEN}>>> Baseline bs=$BS${NC}"
    fio --name=fresh_read_base --filename="$FRESH_FILE" --size="$SIZE" --bs="$BS" \
        --rw=read --direct=1 --ioengine=sync --runtime=5 --time_based --numjobs=1 \
        --group_reporting --unlink=0 --output-format=json > "$RESULTDIR/fresh_base_${BS}.json" 2>/dev/null
    python3 - << PYEOF
import json
with open('$RESULTDIR/fresh_base_${BS}.json') as f:
    d = json.load(f)
bw = d['jobs'][0]['read']['bw'] / 1024
print(f"  bw={bw:.1f} MB/s")
PYEOF

    # Hook RAW
    rm -f "$FRESH_FILE"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if=/dev/zero of="$FRESH_FILE" bs=1M count=512 status=none
    sync
    echo -e "${GREEN}>>> Hook RAW bs=$BS${NC}"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name=fresh_read_hook --filename="$FRESH_FILE" --size="$SIZE" --bs="$BS" \
            --rw=read --direct=1 --ioengine=sync --runtime=5 --time_based --numjobs=1 \
            --group_reporting --unlink=0 --output-format=json > "$RESULTDIR/fresh_hook_${BS}.json" 2>/dev/null
    python3 - << PYEOF
import json
with open('$RESULTDIR/fresh_hook_${BS}.json') as f:
    d = json.load(f)
bw = d['jobs'][0]['read']['bw'] / 1024
print(f"  bw={bw:.1f} MB/s")
PYEOF
done

# ----------------------------------------------------------
#  汇总
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "       写路径 & 混合负载汇总"
echo "========================================"
python3 - << PYEOF
import csv
rows = []
with open('$RESULT_CSV') as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

print(f"{'Scenario':<20} {'BS':<6} {'Jobs':<6} {'RW':<10} {'Mix':<4} {'BW(MB/s)':>10} {'IOPS':>8} {'Lat(us)':>10}")
print("-" * 90)
for r in rows:
    print(f"{r['scenario']:<20} {r['bs']:<6} {r['jobs']:<6} {r['rw']:<10} {r['rwmixread']:<4} {float(r['bw_mb_s']):>10.1f} {float(r['iops']):>8.0f} {float(r['lat_us']):>10.1f}")

print("\n--- Hook vs Baseline 比例（并发写）---")
base = {}
hook = {}
for r in rows:
    if r['scenario'] == 'baseline_write':
        base[(r['bs'], r['jobs'])] = float(r['bw_mb_s'])
    elif r['scenario'] == 'hook_raw_write':
        hook[(r['bs'], r['jobs'])] = float(r['bw_mb_s'])
for k in sorted(base.keys()):
    if k in hook:
        print(f"  bs={k[0]} jobs={k[1]}: {hook[k]/base[k]*100:.1f}%")
PYEOF

echo ""
echo -e "${GREEN}完成。CSV: $RESULT_CSV${NC}"
rm -rf "$TESTDIR"
