#!/bin/bash
set -e

# ============================================================
#  Production Metrics Test
# ============================================================
# 收集生产环境关注的核心指标：
#   1. p99 / p999 读延迟（fio JSON percentile）
#   2. CPU 使用率（mpstat）
#   3. 上下文切换（vmstat / pidstat）
#   4. syscall 次数（strace -c）
#   5. 内存带宽（perf stat，可选）
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_production_metrics_$$"
RESULTDIR="/tmp/gpuc_production_metrics_results_$$"

mkdir -p "$TESTDIR" "$RESULTDIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

RESULT_LOG="$RESULTDIR/results.log"
echo "Production Metrics Test Results" > "$RESULT_LOG"
echo "================================" >> "$RESULT_LOG"

PASS=0
FAIL=0
SKIP=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    echo "PASS: $1" >> "$RESULT_LOG"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "FAIL: $1" >> "$RESULT_LOG"
    FAIL=$((FAIL + 1))
}

skip() {
    echo -e "${BLUE}SKIP${NC}: $1"
    echo "SKIP: $1" >> "$RESULT_LOG"
    SKIP=$((SKIP + 1))
}

# ----------------------------------------------------------
#  准备测试数据
# ----------------------------------------------------------
prepare_data() {
    echo ""
    echo -e "${YELLOW}### 准备 512 MB 全零可压缩测试文件 ###${NC}"
    local testfile="$TESTDIR/metrics.bin"
    rm -f "$testfile"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        dd if=/dev/zero of="$testfile" bs=1M count=512 status=none
    "$GPU_DAEMON" "$TESTDIR" >/dev/null 2>&1
    echo "文件状态:"
    ls -lh "$testfile" >> "$RESULT_LOG"
}

# ----------------------------------------------------------
#  1. p99 / p999 尾延迟
# ----------------------------------------------------------
test_tail_latency() {
    echo ""
    echo -e "${YELLOW}### 1. p99 / p999 尾延迟 ###${NC}"
    local testfile="$TESTDIR/metrics.bin"
    local json_out="$RESULTDIR/fio_tail_latency.json"

    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name=tail_lat \
            --filename="$testfile" \
            --size=512M \
            --bs=128k \
            --rw=randread \
            --direct=1 \
            --ioengine=sync \
            --runtime=20 \
            --time_based \
            --numjobs=1 \
            --group_reporting \
            --unlink=0 \
            --output-format=json > "$json_out" 2>/dev/null

    if [ -f "$json_out" ] && python3 - << PY
import json, sys
with open('$json_out') as f:
    d = json.load(f)
jobs = d.get('jobs', [])
if not jobs:
    sys.exit(1)
job = jobs[0]
lat = job.get('read', {}).get('clat_ns', {})
pct = lat.get('percentile', {})
p50 = pct.get('50.000000')
p99 = pct.get('99.000000')
p999 = pct.get('99.900000')
iops = job.get('read', {}).get('iops', 0)
bw = job.get('read', {}).get('bw', 0)
if p50 is None or p99 is None or p999 is None:
    sys.exit(1)
print(f"IOPS={iops:.0f}  BW={bw/1024:.1f} MiB/s")
print(f"p50={p50/1000:.1f} us  p99={p99/1000:.1f} us  p999={p999/1000:.1f} us")
PY
    then
        pass "p99/p999 尾延迟已收集（见 $json_out）"
    else
        fail "fio 未生成有效 JSON 或缺少 percentile 数据"
    fi
}

# ----------------------------------------------------------
#  2. CPU 使用率
# ----------------------------------------------------------
test_cpu_usage() {
    echo ""
    echo -e "${YELLOW}### 2. CPU 使用率 ###${NC}"
    local testfile="$TESTDIR/metrics.bin"
    local mpstat_out="$RESULTDIR/mpstat.log"

    if ! command -v mpstat >/dev/null 2>&1; then
        skip "mpstat 未安装"
        return
    fi

    mpstat -P ALL 1 10 > "$mpstat_out" &
    local mpstat_pid=$!

    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name=cpu_load \
            --filename="$testfile" \
            --size=512M \
            --bs=128k \
            --rw=read \
            --direct=1 \
            --ioengine=sync \
            --runtime=10 \
            --time_based \
            --numjobs=4 \
            --group_reporting \
            --unlink=0 >/dev/null 2>&1 || true

    sleep 1
    kill $mpstat_pid 2>/dev/null || true
    wait $mpstat_pid 2>/dev/null || true

    if [ -s "$mpstat_out" ]; then
        echo "mpstat 平均 CPU 占用（%usr+%sys）:"
        python3 - << PY
import re
data = {}
with open('$mpstat_out') as f:
    header = None
    for line in f:
        line = line.strip()
        if not line or line.startswith('Average') or line.startswith('Linux'):
            continue
        parts = line.split()
        # 识别 header 行
        if header is None and 'CPU' in parts and '%usr' in parts:
            header = parts
            continue
        if header is None:
            continue
        try:
            cpu_idx = header.index('CPU')
            usr_idx = header.index('%usr')
            sys_idx = header.index('%sys')
        except ValueError:
            continue
        if len(parts) <= max(cpu_idx, usr_idx, sys_idx):
            continue
        cpu = parts[cpu_idx]
        try:
            usr = float(parts[usr_idx])
            sys = float(parts[sys_idx])
        except ValueError:
            continue
        data.setdefault(cpu, []).append(usr + sys)
for cpu in sorted(data.keys(), key=lambda x: x if x != 'all' else 'zzz'):
    avg = sum(data[cpu]) / len(data[cpu]) if data[cpu] else 0
    print(f"  CPU {cpu}: {avg:.1f}%")
PY
        pass "CPU 使用率已收集（见 $mpstat_out）"
    else
        fail "mpstat 输出为空"
    fi
}

# ----------------------------------------------------------
#  3. 上下文切换
# ----------------------------------------------------------
test_ctx_switches() {
    echo ""
    echo -e "${YELLOW}### 3. 上下文切换 ###${NC}"
    local testfile="$TESTDIR/metrics.bin"
    local vmstat_out="$RESULTDIR/vmstat.log"

    vmstat 1 10 > "$vmstat_out" &
    local vmstat_pid=$!

    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name=ctx_load \
            --filename="$testfile" \
            --size=512M \
            --bs=128k \
            --rw=randread \
            --direct=1 \
            --ioengine=sync \
            --runtime=8 \
            --time_based \
            --numjobs=8 \
            --group_reporting \
            --unlink=0 >/dev/null 2>&1 || true

    sleep 1
    kill $vmstat_pid 2>/dev/null || true
    wait $vmstat_pid 2>/dev/null || true

    if [ -s "$vmstat_out" ]; then
        echo "vmstat 平均上下文切换（cs/s）:"
        python3 - << PY
import re
vals = []
with open('$vmstat_out') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('procs'):
            continue
        parts = line.split()
        if len(parts) >= 12 and re.match(r'^\d+$', parts[11]):
            vals.append(int(parts[11]))
if vals:
    avg = sum(vals) / len(vals)
    print(f"  avg cs/s = {avg:.0f}")
else:
    print("  无有效数据")
PY
        pass "上下文切换已收集（见 $vmstat_out）"
    else
        fail "vmstat 输出为空"
    fi
}

# ----------------------------------------------------------
#  4. syscall 次数
# ----------------------------------------------------------
test_syscall_count() {
    echo ""
    echo -e "${YELLOW}### 4. syscall 次数 ###${NC}"
    local testfile="$TESTDIR/metrics.bin"
    local strace_out="$RESULTDIR/strace_count.log"

    if ! command -v strace >/dev/null 2>&1; then
        skip "strace 未安装"
        return
    fi

    # 跑 1 秒够用的短测试，避免 strace 数据过大
    strace -c -f -o "$strace_out" \
        env LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name=strace_fio \
            --filename="$testfile" \
            --size=64M \
            --bs=128k \
            --rw=read \
            --direct=1 \
            --ioengine=sync \
            --runtime=2 \
            --time_based \
            --numjobs=1 \
            --group_reporting \
            --unlink=0 >/dev/null 2>&1 || true

    if [ -s "$strace_out" ]; then
        echo "strace 汇总（前 10 高频 syscall）:"
        tail -n +3 "$strace_out" | head -12
        pass "syscall 统计已收集（见 $strace_out）"
    else
        fail "strace 输出为空"
    fi
}

# ----------------------------------------------------------
#  5. 内存带宽（可选）
# ----------------------------------------------------------
test_memory_bandwidth() {
    echo ""
    echo -e "${YELLOW}### 5. 内存带宽（perf，可选）###${NC}"
    local testfile="$TESTDIR/metrics.bin"
    local perf_out="$RESULTDIR/perf_mem.log"

    if ! command -v perf >/dev/null 2>&1; then
        skip "perf 未安装"
        return
    fi

    # 检查 perf 是否能找到对应内核版本的工具
    if ! perf --version >/dev/null 2>&1; then
        skip "perf  wrapper 无法找到匹配内核版本的 perf 二进制"
        return
    fi

    # sudo 辅助函数
    _sudo_perf() {
        if sudo -n "$@" 2>/dev/null; then
            return 0
        elif [ -n "${SUDO_PASSWORD:-}" ]; then
            echo "$SUDO_PASSWORD" | sudo -S "$@" 2>/dev/null
            return $?
        else
            return 1
        fi
    }

    # perf uncore_imc 通常需要 root；失败则优雅跳过
    if ! _sudo_perf perf stat -e uncore_imc/cas_count_read/,uncore_imc/cas_count_write/ \
         -o "$perf_out" \
         env LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
         fio --name=perf_mem \
             --filename="$testfile" \
             --size=128M \
             --bs=128k \
             --rw=read \
             --direct=1 \
             --ioengine=sync \
             --runtime=5 \
             --time_based \
             --numjobs=1 \
             --group_reporting \
             --unlink=0 >/dev/null 2>&1; then
        skip "perf 内存带宽事件无法采集（可能需要 root、CPU 不支持 uncore_imc 或缺少匹配内核版本的 perf 二进制）"
        return
    fi

    if [ -s "$perf_out" ]; then
        echo "perf 内存事件统计:"
        grep -E "CAS|count" "$perf_out" || cat "$perf_out"
        pass "内存带宽事件已收集（见 $perf_out）"
    else
        fail "perf 输出为空"
    fi
}

# ----------------------------------------------------------
#  主流程
# ----------------------------------------------------------
echo "========================================"
echo "  Production Metrics Test"
echo "========================================"
echo "测试目录: $TESTDIR"
echo "结果目录: $RESULTDIR"
echo "========================================"

prepare_data
test_tail_latency
test_cpu_usage
test_ctx_switches
test_syscall_count
test_memory_bandwidth

echo ""
echo "========================================"
echo "       汇总"
echo "========================================"
echo -e "${GREEN}PASS: $PASS${NC}"
echo -e "${RED}FAIL: $FAIL${NC}"
echo -e "${BLUE}SKIP: $SKIP${NC}"
echo ""
echo "详细日志: $RESULT_LOG"
echo "原始数据: $RESULTDIR"

rm -rf "$TESTDIR"
