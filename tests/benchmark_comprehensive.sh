#!/bin/bash
set -e

# ============================================================
#  GPU Compress - 全面性能基准测试脚本
# ============================================================
# 测试维度：
#   1. 数据类型：zero, rand, rep(重复), mixed
#   2. 文件大小：512B(inline), 1MB, 512MB
#   3. I/O 大小：128k, 1M
#   4. 操作模式：顺序读(read), 顺序写(write), 随机读(randread)
#   5. 并发度：1, 4, 8
#   6. 状态对比：Baseline, Hook RAW, Hook COMPRESSED, Hook INLINE
#   7. GPU vs CPU 后端对比
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
CPU_HOOK_SO="$PROJECT_DIR/bin/libcpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
CPU_DAEMON="$PROJECT_DIR/bin/cpu_compress_daemon"
TESTDIR="/tmp/gpuc_benchmark_$$"
RESULTDIR="/tmp/gpuc_benchmark_results_$$"

mkdir -p "$TESTDIR" "$RESULTDIR"

RUNTIME=5
LARGE_SIZE="512M"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/results.csv"
echo "tag,scenario,pattern,size,bs,jobs,rw,bw_mb_s,iops,lat_us,state,extra" > "$RESULT_CSV"

# ----------------------------------------------------------
run_fio() {
    local tag=$1
    local scenario=$2
    local rw=$3
    local preload=$4
    local pattern=$5
    local size=$6
    local bs=$7
    local jobs=${8:-1}
    local state=${9:-N/A}
    local testfile="$TESTDIR/fio_${pattern}_${size}_${bs}.bin"
    local json_out="$RESULTDIR/${tag}.json"

    local extra_opts=""
    if [ "$pattern" = "zero" ]; then
        extra_opts="--buffer_pattern=0x00"
    elif [ "$pattern" = "rep" ]; then
        extra_opts="--buffer_pattern=0xAB"
    fi

    local unlink_opt=""
    if [ "$rw" = "write" ]; then
        unlink_opt="--unlink=1"
    fi

    if [ -n "$preload" ]; then
        export LD_PRELOAD="$preload"
        export GPUCOMPRESS_QUIET=1
    else
        unset LD_PRELOAD
        unset GPUCOMPRESS_QUIET
    fi

    fio \
        --name="$tag" \
        --filename="$testfile" \
        --size="$size" \
        --bs="$bs" \
        --rw="$rw" \
        --direct=0 \
        --ioengine=sync \
        --runtime="$RUNTIME" \
        --time_based \
        --numjobs="$jobs" \
        --group_reporting \
        $unlink_opt \
        $extra_opts \
        --output-format=json \
        > "$json_out" 2>/dev/null || true

    python3 << EOF
import json, sys
try:
    with open("$json_out") as f:
        d = json.load(f)
    job = d['jobs'][0]
    bw_r = job['read']['bw'] / 1024
    bw_w = job['write']['bw'] / 1024
    iops_r = job['read']['iops']
    iops_w = job['write']['iops']
    lat_r = job['read']['lat_ns']['mean'] / 1000 if job['read']['lat_ns']['mean'] > 0 else 0
    lat_w = job['write']['lat_ns']['mean'] / 1000 if job['write']['lat_ns']['mean'] > 0 else 0
    if bw_r > 0:
        bw, iops, lat = bw_r, iops_r, lat_r
        rw_mode = "read"
    else:
        bw, iops, lat = bw_w, iops_w, lat_w
        rw_mode = "write"
    with open("$RESULT_CSV", "a") as out:
        out.write(f"$tag,$scenario,$pattern,$size,$bs,$jobs,{rw_mode},{bw:.1f},{iops:.0f},{lat:.1f},$state,\n")
    print(f"  BW={bw:.1f} MB/s  IOPS={iops:.0f}  LAT={lat:.1f} us")
except Exception as e:
    print(f"  ERROR: {e}")
    with open("$RESULT_CSV", "a") as out:
        out.write(f"$tag,$scenario,$pattern,$size,$bs,$jobs,$rw,0,0,0,$state,error\n")
EOF
}

# ----------------------------------------------------------
gen_file() {
    local path=$1
    local size=$2
    local pattern=$3

    if [ "$pattern" = "zero" ]; then
        dd if=/dev/zero of="$path" bs=1M count=$(($size / 1024 / 1024)) 2>/dev/null || \
            dd if=/dev/zero of="$path" bs=$size count=1 2>/dev/null
    elif [ "$pattern" = "rand" ]; then
        dd if=/dev/urandom of="$path" bs=1M count=$(($size / 1024 / 1024)) 2>/dev/null || \
            dd if=/dev/urandom of="$path" bs=$size count=1 2>/dev/null
    elif [ "$pattern" = "rep" ]; then
        python3 -c "
bs = 1024 * 1024
block = bytes([0xAB] * bs)
remaining = $size
with open('$path', 'wb') as f:
    while remaining > 0:
        to_write = min(bs, remaining)
        f.write(block[:to_write])
        remaining -= to_write
" 2>/dev/null
    elif [ "$pattern" = "mixed" ]; then
        python3 -c "
import random
bs = 1024 * 1024
size = $size
half = size // 2
random.seed(0x12345678)
block_rep = bytes([i % 7 for i in range(bs)])
with open('$path', 'wb') as f:
    remaining = half
    while remaining > 0:
        to_write = min(bs, remaining)
        f.write(block_rep[:to_write])
        remaining -= to_write
    remaining = size - half
    while remaining > 0:
        to_write = min(bs, remaining)
        f.write(bytes([random.randint(0, 255) for _ in range(to_write)]))
        remaining -= to_write
" 2>/dev/null
    fi
}

# ----------------------------------------------------------
run_compression_ratio() {
    local pattern=$1
    local size=$2

    echo -e "${BLUE}>>> COMPRESSION RATIO: $pattern ($size)${NC}"

    local rawfile="$TESTDIR/ratio_${pattern}.bin"
    gen_file "$rawfile" "$size" "$pattern"
    local raw_size=$(stat -c %s "$rawfile")

    local hookfile="$TESTDIR/ratio_hook_${pattern}.bin"
    export LD_PRELOAD="$HOOK_SO"
    export GPUCOMPRESS_QUIET=1
    dd if="$rawfile" of="$hookfile" bs=1M 2>/dev/null
    unset LD_PRELOAD
    unset GPUCOMPRESS_QUIET

    local hook_raw_size=$(stat -c %s "$hookfile")

    "$GPU_DAEMON" "$TESTDIR" 2>/dev/null || true

    local hook_comp_phys=$(du -B1 "$hookfile" | awk '{print $1}')
    local comp_ratio=$(python3 -c "print(f'{$hook_comp_phys / $raw_size * 100:.1f}')")

    echo "  Raw=${raw_size}B  Hook RAW=${hook_raw_size}B  Hook PHYS=${hook_comp_phys}B  Ratio=${comp_ratio}%"
    echo "compression_ratio,$pattern,${size}B,N/A,N/A,write,0,0,0,COMPRESSED,$comp_ratio" >> "$RESULT_CSV"
}

# ----------------------------------------------------------
run_daemon_time() {
    local pattern=$1
    local size=$2

    echo -e "${BLUE}>>> DAEMON TIME: $pattern ($size)${NC}"

    local testfile="$TESTDIR/daemon_${pattern}.bin"
    gen_file "$testfile" "$size" "$pattern"

    local hookfile="$TESTDIR/daemon_hook_${pattern}.bin"
    export LD_PRELOAD="$HOOK_SO"
    export GPUCOMPRESS_QUIET=1
    dd if="$testfile" of="$hookfile" bs=1M 2>/dev/null
    unset LD_PRELOAD
    unset GPUCOMPRESS_QUIET

    local t0=$(date +%s.%N)
    "$GPU_DAEMON" "$TESTDIR" 2>/dev/null || true
    local t1=$(date +%s.%N)

    local dt=$(python3 -c "print(f'{$t1 - $t0:.3f}')")
    local throughput=$(python3 -c "print(f'{$size / 1024 / 1024 / ($t1 - $t0):.1f}')")
    echo "  Time=${dt}s  Throughput=${throughput} MB/s"
    echo "daemon_time,$pattern,${size}B,N/A,N/A,write,0,0,0,COMPRESSED,$dt,${throughput}MBs" >> "$RESULT_CSV"
}

# ----------------------------------------------------------
run_inline_test() {
    local size=$1
    echo -e "${BLUE}>>> INLINE TEST: size=$size${NC}"

    local testfile="$TESTDIR/inline_${size}.bin"
    export LD_PRELOAD="$HOOK_SO"
    export GPUCOMPRESS_QUIET=1
    python3 -c "
with open('$testfile', 'wb') as f:
    f.write(bytes([i % 256 for i in range($size)]))
" 2>/dev/null
    unset LD_PRELOAD
    unset GPUCOMPRESS_QUIET

    "$GPU_DAEMON" "$TESTDIR" 2>/dev/null || true

    python3 -c "
import struct
with open('$testfile', 'rb') as f:
    hdr = f.read(56)
    state = hdr[24]
    orig_size = struct.unpack('<Q', hdr[8:16])[0]
    header_size = struct.unpack('<Q', hdr[32:40])[0]
    assert state == 3, f'Expected INLINE, got {state}'
    print(f'  INLINE verified: orig_size={orig_size} header_size={header_size}')
" || echo "  INLINE verification FAILED"

    export LD_PRELOAD="$HOOK_SO"
    export GPUCOMPRESS_QUIET=1
    local t0=$(date +%s.%N)
    for i in $(seq 1 1000); do
        python3 -c "
with open('$testfile', 'rb') as f:
    data = f.read()
" 2>/dev/null
    done
    local t1=$(date +%s.%N)
    unset LD_PRELOAD
    unset GPUCOMPRESS_QUIET

    local avg_lat=$(python3 -c "print(f'{($t1 - $t0) * 1000000 / 1000:.1f}')")
    echo "  1000 reads: avg latency=${avg_lat} us"
    echo "inline_read,inline,rep,${size}B,N/A,1,read,0,0,$avg_lat,INLINE,1000reads" >> "$RESULT_CSV"
}

# ----------------------------------------------------------
main() {
    echo "========================================"
    echo "  GPU Compress - 全面性能基准测试"
    echo "========================================"
    echo "测试目录: $TESTDIR"
    echo "结果目录: $RESULTDIR"
    echo "========================================"

    if ! which fio >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] fio 未安装。请执行: sudo apt-get install fio${NC}"
        exit 1
    fi

    # ============================================================
    echo ""
    echo "########## PART 1: Inline 小文件测试 ##########"
    run_inline_test 512
    run_inline_test 1024

    # ============================================================
    echo ""
    echo "########## PART 2: 压缩率测试 ##########"
    run_compression_ratio "zero" 524288000
    run_compression_ratio "rand" 524288000
    run_compression_ratio "rep" 524288000
    run_compression_ratio "mixed" 524288000

    # ============================================================
    echo ""
    echo "########## PART 3: Daemon 压缩耗时 ##########"
    run_daemon_time "zero" 524288000
    run_daemon_time "rand" 524288000
    run_daemon_time "rep" 524288000

    # ============================================================
    echo ""
    echo "########## PART 4: fio 基准测试 (512MB) ##########"

    for PATTERN in zero rand rep; do
        echo ""
        echo -e "${YELLOW}--- 顺序写 128k: $PATTERN ---${NC}"
        run_fio "baseline_write_${PATTERN}_512M_128k" "baseline" "write" "" "$PATTERN" "$LARGE_SIZE" "128k" 1 "N/A"
        run_fio "hook_raw_write_${PATTERN}_512M_128k" "hook_raw" "write" "$HOOK_SO" "$PATTERN" "$LARGE_SIZE" "128k" 1 "RAW"
    done

    for PATTERN in zero rand rep; do
        echo ""
        echo -e "${YELLOW}--- 顺序读 128k: $PATTERN ---${NC}"
        run_fio "baseline_read_${PATTERN}_512M_128k" "baseline" "read" "" "$PATTERN" "$LARGE_SIZE" "128k" 1 "N/A"
        run_fio "hook_raw_read_${PATTERN}_512M_128k" "hook_raw" "read" "$HOOK_SO" "$PATTERN" "$LARGE_SIZE" "128k" 1 "RAW"

        local testfile="$TESTDIR/fio_${PATTERN}_${LARGE_SIZE}_128k.bin"
        if [ -f "$testfile" ]; then
            "$GPU_DAEMON" "$TESTDIR" 2>/dev/null || true
            run_fio "gpu_compressed_read_${PATTERN}_512M_128k" "gpu_compressed" "read" "$HOOK_SO" "$PATTERN" "$LARGE_SIZE" "128k" 1 "COMPRESSED"
        fi

        rm -f "$testfile"
        run_fio "hook_raw_write2_${PATTERN}_512M_128k" "hook_raw" "write" "$HOOK_SO" "$PATTERN" "$LARGE_SIZE" "128k" 1 "RAW"
        if [ -f "$testfile" ]; then
            "$CPU_DAEMON" "$TESTDIR" 2>/dev/null || true
            GPUCOMPRESS_BACKEND=cpu run_fio "cpu_compressed_read_${PATTERN}_512M_128k" "cpu_compressed" "read" "$HOOK_SO" "$PATTERN" "$LARGE_SIZE" "128k" 1 "COMPRESSED"
        fi
    done

    for PATTERN in zero rand; do
        echo ""
        echo -e "${YELLOW}--- 顺序读 1M: $PATTERN ---${NC}"
        run_fio "baseline_read_${PATTERN}_512M_1M" "baseline" "read" "" "$PATTERN" "$LARGE_SIZE" "1M" 1 "N/A"
        run_fio "hook_raw_read_${PATTERN}_512M_1M" "hook_raw" "read" "$HOOK_SO" "$PATTERN" "$LARGE_SIZE" "1M" 1 "RAW"

        local testfile="$TESTDIR/fio_${PATTERN}_${LARGE_SIZE}_1M.bin"
        if [ -f "$testfile" ]; then
            "$GPU_DAEMON" "$TESTDIR" 2>/dev/null || true
            run_fio "gpu_compressed_read_${PATTERN}_512M_1M" "gpu_compressed" "read" "$HOOK_SO" "$PATTERN" "$LARGE_SIZE" "1M" 1 "COMPRESSED"
        fi
    done

    echo ""
    echo -e "${YELLOW}--- 随机读 128k (zero) ---${NC}"
    run_fio "baseline_randread_zero_512M_128k" "baseline" "randread" "" "zero" "$LARGE_SIZE" "128k" 1 "N/A"
    run_fio "hook_raw_randread_zero_512M_128k" "hook_raw" "randread" "$HOOK_SO" "zero" "$LARGE_SIZE" "128k" 1 "RAW"
    local testfile="$TESTDIR/fio_zero_${LARGE_SIZE}_128k.bin"
    if [ -f "$testfile" ]; then
        "$GPU_DAEMON" "$TESTDIR" 2>/dev/null || true
        run_fio "gpu_compressed_randread_zero_512M_128k" "gpu_compressed" "randread" "$HOOK_SO" "zero" "$LARGE_SIZE" "128k" 1 "COMPRESSED"
    fi

    echo ""
    echo -e "${YELLOW}--- 多线程并发 (zero, 128k) ---${NC}"
    for JOBS in 1 4 8; do
        run_fio "baseline_read_zero_512M_128k_j${JOBS}" "baseline" "read" "" "zero" "$LARGE_SIZE" "128k" "$JOBS" "N/A"
        run_fio "hook_raw_read_zero_512M_128k_j${JOBS}" "hook_raw" "read" "$HOOK_SO" "zero" "$LARGE_SIZE" "128k" "$JOBS" "RAW"
        local testfile="$TESTDIR/fio_zero_${LARGE_SIZE}_128k.bin"
        if [ -f "$testfile" ]; then
            "$GPU_DAEMON" "$TESTDIR" 2>/dev/null || true
            run_fio "gpu_compressed_read_zero_512M_128k_j${JOBS}" "gpu_compressed" "read" "$HOOK_SO" "zero" "$LARGE_SIZE" "128k" "$JOBS" "COMPRESSED"
        fi
    done

    # ============================================================
    echo ""
    echo "########## PART 5: dd 吞吐测试 ##########"
    for PATTERN in zero rand rep; do
        local ddfile="$TESTDIR/dd_${PATTERN}_512M.bin"
        gen_file "$ddfile" 524288000 "$PATTERN"

        local t0=$(date +%s.%N)
        dd if="$ddfile" of=/dev/null bs=1M iflag=direct 2>/dev/null
        local t1=$(date +%s.%N)
        local bw=$(python3 -c "print(f'{512 / ($t1 - $t0):.1f}')")
        echo "  Baseline dd read ($PATTERN): ${bw} MB/s"
        echo "dd_baseline,$pattern,512M,1M,1,read,$bw,0,0,N/A,0" >> "$RESULT_CSV"

        export LD_PRELOAD="$HOOK_SO"
        export GPUCOMPRESS_QUIET=1
        t0=$(date +%s.%N)
        dd if="$ddfile" of=/dev/null bs=1M iflag=direct 2>/dev/null
        t1=$(date +%s.%N)
        bw=$(python3 -c "print(f'{512 / ($t1 - $t0):.1f}')")
        echo "  Hook RAW dd read ($PATTERN): ${bw} MB/s"
        unset LD_PRELOAD
        unset GPUCOMPRESS_QUIET
        echo "dd_hook_raw,$pattern,512M,1M,1,read,$bw,0,0,RAW,0" >> "$RESULT_CSV"
    done

    # ============================================================
    echo ""
    echo "========================================"
    echo "       性能对比报告"
    echo "========================================"
    echo ""
    echo "CSV: $RESULT_CSV"
    echo ""
    python3 << EOF
import csv
with open("$RESULT_CSV") as f:
    reader = csv.DictReader(f)
    rows = list(reader)
if rows:
    print(f"{'测试项':<50} {'场景':<14} {'数据':<8} {'大小':<8} {'BS':<6} {'并发':<4} {'模式':<6} {'带宽(MB/s)':>12} {'IOPS':>10} {'延迟(us)':>10} {'状态':>10}")
    print("-" * 142)
    for r in rows:
        tag = r['tag'][:48]
        print(f"{tag:<50} {r['scenario']:<14} {r['pattern']:<8} {r['size']:<8} {r['bs']:<6} {r['jobs']:<4} {r['rw']:<6} {r['bw_mb_s']:>12} {r['iops']:>10} {r['lat_us']:>10} {r['state']:>10}")
EOF

    echo ""
    echo -e "${GREEN}全部测试完成！${NC}"
    cp "$RESULT_CSV" /tmp/gpuc_latest_results.csv
}

main "$@"
