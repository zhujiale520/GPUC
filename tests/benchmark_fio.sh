#!/bin/bash
set -e

# ============================================================
#  GPU Compress - fio 性能基准测试脚本 (修正版)
# ============================================================
# 修复：确保 daemon 压缩前文件未被 unlink 删除
#
# 测试维度：
#   1. Baseline (纯 CPU，不加载 hook)
#   2. Hook RAW (加载 hook，文件未压缩)
#   3. CPU Compressed (CPU daemon 压缩后读取)
#   4. GPU Compressed (GPU daemon 压缩后读取)
#
# 数据模式：
#   - zero: 全零（高压缩率）
#   - rand: 随机（不可压缩）
#
# 收集指标：带宽(MB/s)、IOPS、延迟(us)、GPU 利用率
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
CPU_HOOK_SO="$PROJECT_DIR/bin/libcpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
CPU_DAEMON="$PROJECT_DIR/bin/cpu_compress_daemon"
TESTDIR="/tmp/gpuc_fio_test"

# 测试参数
SIZE="512M"      # 测试文件大小
RUNTIME=10       # 每个测试跑 10 秒
BS_LIST="128k 1M" # 块大小列表
JOBS=1           # 并发数

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ----------------------------------------------------------
#  前置检查
# ----------------------------------------------------------
check_deps() {
    echo "[CHECK] 检查依赖..."
    if ! which fio >/dev/null 2>&1; then
        echo -e "${RED}[ERROR] fio 未安装。请执行: sudo apt-get install fio${NC}"
        exit 1
    fi
    if [ ! -f "$HOOK_SO" ]; then
        echo -e "${RED}[ERROR] $HOOK_SO 不存在。请先执行: make all${NC}"
        exit 1
    fi
    if [ ! -f "$GPU_DAEMON" ]; then
        echo -e "${RED}[ERROR] $GPU_DAEMON 不存在。请先执行: make all${NC}"
        exit 1
    fi
    if ! which nvidia-smi >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARN] nvidia-smi 未找到，GPU 监控将不可用${NC}"
    fi
    echo -e "${GREEN}[OK] 依赖检查通过${NC}"
}

# ----------------------------------------------------------
#  后台采样 GPU 利用率
# ----------------------------------------------------------
sample_gpu() {
    local out=$1
    rm -f "$out"
    while true; do
        if which nvidia-smi >/dev/null 2>&1; then
            nvidia-smi --query-gpu=utilization.gpu,utilization.memory,memory.used \
                       --format=csv,noheader,nounits >> "$out" 2>/dev/null
        fi
        sleep 1
    done
}

# ----------------------------------------------------------
#  运行 fio 测试
#  参数: tag rw preload pattern bs [unlink_flag]
# ----------------------------------------------------------
run_fio() {
    local tag=$1
    local rw=$2
    local preload=$3
    local pattern=$4
    local bs=$5
    local unlink_flag="${6:-1}"
    local testfile="$TESTDIR/fio_${pattern}_${bs}.bin"
    local json_out="/tmp/fio_${tag}.json"
    local gpu_log="/tmp/gpu_${tag}.log"

    echo ""
    echo -e "${YELLOW}>>> TEST: $tag (rw=$rw, bs=$bs, pattern=$pattern, unlink=$unlink_flag)${NC}"

    # 启动 GPU 采样
    if which nvidia-smi >/dev/null 2>&1; then
        sample_gpu "$gpu_log" &
        local gpu_pid=$!
    fi

    # 运行 fio
    if [ -n "$preload" ]; then
        export LD_PRELOAD="$preload"
        export GPUCOMPRESS_QUIET=1
    else
        unset LD_PRELOAD
        unset GPUCOMPRESS_QUIET
    fi

    # 根据 pattern 选择数据生成方式
    local extra_opts=""
    if [ "$pattern" = "zero" ]; then
        extra_opts="--buffer_pattern=0x00"
    fi

    local unlink_opt=""
    if [ "$unlink_flag" = "1" ]; then
        unlink_opt="--unlink=1"
    fi

    fio \
        --name="$tag" \
        --filename="$testfile" \
        --size="$SIZE" \
        --bs="$bs" \
        --rw="$rw" \
        --direct=0 \
        --ioengine=sync \
        --runtime="$RUNTIME" \
        --time_based \
        --numjobs="$JOBS" \
        --group_reporting \
        $unlink_opt \
        $extra_opts \
        --output-format=json \
        > "$json_out" 2>/tmp/fio_${tag}.err

    # 停止 GPU 采样
    if [ -n "$gpu_pid" ]; then
        kill $gpu_pid 2>/dev/null || true
        wait $gpu_pid 2>/dev/null || true
    fi

    # 解析结果
    parse_result "$tag" "$json_out" "$gpu_log"
}

# ----------------------------------------------------------
#  解析 fio JSON + GPU 日志
# ----------------------------------------------------------
parse_result() {
    local tag=$1
    local json=$2
    local gpu_log=$3

    python3 << EOF
import json, sys, os

def fmt_bw(kb):
    return f"{kb/1024:.1f}"

def fmt_iops(iops):
    return f"{iops:.0f}"

def fmt_lat(ns):
    return f"{ns/1000:.1f}"

try:
    with open('$json') as f:
        d = json.load(f)
    job = d['jobs'][0]
    
    bw_r = job['read']['bw'] / 1024
    bw_w = job['write']['bw'] / 1024
    iops_r = job['read']['iops']
    iops_w = job['write']['iops']
    lat_r = job['read']['lat_ns']['mean'] / 1000 if job['read']['lat_ns']['mean'] > 0 else 0
    lat_w = job['write']['lat_ns']['mean'] / 1000 if job['write']['lat_ns']['mean'] > 0 else 0
    
    if bw_r > 0:
        print(f"  Bandwidth: {bw_r:.1f} MB/s (read)")
        print(f"  IOPS:      {iops_r:.0f}")
        print(f"  Latency:   {lat_r:.1f} us")
    elif bw_w > 0:
        print(f"  Bandwidth: {bw_w:.1f} MB/s (write)")
        print(f"  IOPS:      {iops_w:.0f}")
        print(f"  Latency:   {lat_w:.1f} us")
    else:
        print("  WARNING: no read/write data found")
        
except Exception as e:
    print(f"  ERROR: {e}")
    print(f"  (查看原始日志: $json)")

# GPU 统计
try:
    if os.path.exists('$gpu_log') and os.path.getsize('$gpu_log') > 0:
        with open('$gpu_log') as f:
            lines = [l.strip() for l in f if l.strip()]
        if lines:
            gpus = [float(l.split(',')[0].strip()) for l in lines]
            mems = [float(l.split(',')[1].strip()) for l in lines]
            memuse = [float(l.split(',')[2].strip()) for l in lines]
            print(f"  GPU Util:  {sum(gpus)/len(gpus):.1f}% (avg)")
            print(f"  GPU Mem:   {sum(mems)/len(mems):.1f}% util, {sum(memuse)/len(memuse):.0f} MiB (avg)")
        else:
            print("  GPU Util:  N/A")
    else:
        print("  GPU Util:  N/A")
except Exception as e:
    print(f"  GPU Util:  N/A ({e})")
EOF
}

# ----------------------------------------------------------
#  最终对比报告
# ----------------------------------------------------------
print_report() {
    echo ""
    echo "========================================"
    echo "       性能对比报告"
    echo "========================================"
    
    python3 << EOF
import json, os, glob

tests = []
for fpath in sorted(glob.glob("/tmp/fio_*.json")):
    tag = os.path.basename(fpath).replace("fio_", "").replace(".json", "")
    try:
        with open(fpath) as f:
            d = json.load(f)
        job = d['jobs'][0]
        if job['read']['bw'] > 0:
            bw = job['read']['bw'] / 1024
            iops = job['read']['iops']
            lat = job['read']['lat_ns']['mean'] / 1000
            rw = "read"
        else:
            bw = job['write']['bw'] / 1024
            iops = job['write']['iops']
            lat = job['write']['lat_ns']['mean'] / 1000
            rw = "write"
        tests.append((tag, bw, iops, lat, rw))
    except Exception as e:
        tests.append((tag, 0, 0, 0, "err"))

print(f"{'测试项':<50} {'带宽(MB/s)':>12} {'IOPS':>10} {'延迟(us)':>10} {'模式':>6}")
print("-" * 95)
for tag, bw, iops, lat, rw in tests:
    print(f"{tag:<50} {bw:>12.1f} {iops:>10.0f} {lat:>10.1f} {rw:>6}")

# 压缩效果
print("\n--- 压缩效果 ---")
for pattern in ["zero", "rand"]:
    for bs in ["128k", "1M"]:
        testfile = f"$TESTDIR/fio_{pattern}_{bs}.bin"
        if os.path.exists(testfile):
            try:
                logical = os.path.getsize(testfile)
                if logical == 0:
                    continue
                import subprocess
                physical = int(subprocess.check_output(["du", "-B1", testfile]).decode().split()[0])
                print(f"  {pattern}/{bs}: 逻辑={logical/(1024*1024):.1f}MB 物理={physical/(1024*1024):.1f}MB 压缩率={physical/logical*100:.1f}%")
            except:
                pass
EOF
}

# ----------------------------------------------------------
#  主流程
# ----------------------------------------------------------
main() {
    check_deps

    # 清理环境
    echo ""
    echo "[SETUP] 清理测试环境..."
    rm -rf "$TESTDIR"
    mkdir -p "$TESTDIR"
    rm -f /tmp/fio_*.json /tmp/gpu_*.log /tmp/fio_*.err

    echo "========================================"
    echo "  GPU Compress - fio 性能基准测试"
    echo "========================================"
    echo "测试目录: $TESTDIR"
    echo "文件大小: $SIZE"
    echo "运行时间: ${RUNTIME}s / 每项"
    echo "并发任务: $JOBS"
    echo "========================================"

    for BS in $BS_LIST; do
        echo ""
        echo "########## Block Size = $BS ##########"

        for PATTERN in zero rand; do
            echo ""
            echo "====== Pattern = $PATTERN ======"

            # 1. 基线：纯 CPU 顺序写
            run_fio "baseline_write_${PATTERN}_${BS}" "write" "" "$PATTERN" "$BS" 1

            # 2. 基线：纯 CPU 顺序读
            run_fio "baseline_read_${PATTERN}_${BS}" "read" "" "$PATTERN" "$BS" 1

            # 3. Hook RAW 写（保留文件供后续读取）
            run_fio "hook_write_${PATTERN}_${BS}" "write" "$HOOK_SO" "$PATTERN" "$BS" 0

            # 4. Hook RAW 读（保留文件供 daemon 压缩）
            run_fio "hook_raw_read_${PATTERN}_${BS}" "read" "$HOOK_SO" "$PATTERN" "$BS" 0

            # 5. CPU Daemon 压缩 + Hook 读
            echo ""
            echo -e "${YELLOW}>>> CPU Daemon 压缩 ($PATTERN/$BS)...${NC}"
            TESTFILE="$TESTDIR/fio_${PATTERN}_${BS}.bin"
            if [ -f "$TESTFILE" ]; then
                if "$CPU_DAEMON" "$(dirname "$TESTFILE")"; then
                    run_fio "cpu_compressed_read_${PATTERN}_${BS}" "read" "$HOOK_SO" "$PATTERN" "$BS" 1
                else
                    echo -e "${RED}[WARN] CPU Daemon 压缩失败${NC}"
                fi
            else
                echo -e "${RED}[WARN] 测试文件不存在，跳过 CPU 压缩${NC}"
            fi

            # 6. GPU Daemon 压缩 + GPU hook 读
            echo ""
            echo -e "${YELLOW}>>> GPU Daemon 压缩 ($PATTERN/$BS)...${NC}"
            # 重新写入 RAW 文件（供 GPU daemon 压缩）
            run_fio "hook_write2_${PATTERN}_${BS}" "write" "$HOOK_SO" "$PATTERN" "$BS" 0
            if [ -f "$TESTFILE" ]; then
                if "$GPU_DAEMON" "$(dirname "$TESTFILE")"; then
                    run_fio "gpu_compressed_read_${PATTERN}_${BS}" "read" "$HOOK_SO" "$PATTERN" "$BS" 1
                else
                    echo -e "${RED}[WARN] GPU Daemon 压缩失败${NC}"
                fi
            else
                echo -e "${RED}[WARN] 测试文件不存在，跳过 GPU 压缩${NC}"
            fi

            # 7. CPU Daemon 压缩 + CPU hook 读（纯 CPU 对比）
            echo ""
            echo -e "${YELLOW}>>> CPU hook 压缩对比 ($PATTERN/$BS)...${NC}"
            run_fio "hook_write3_${PATTERN}_${BS}" "write" "$HOOK_SO" "$PATTERN" "$BS" 0
            if [ -f "$TESTFILE" ]; then
                if "$CPU_DAEMON" "$(dirname "$TESTFILE")"; then
                    # 使用纯 CPU hook 库
                    run_fio "cpu_compressed_read_cpuhook_${PATTERN}_${BS}" "read" "$CPU_HOOK_SO" "$PATTERN" "$BS" 1
                    # 使用 GPU hook 库但强制 CPU backend
                    GPUCOMPRESS_BACKEND=cpu run_fio "cpu_compressed_read_gpuhook_cpu_${PATTERN}_${BS}" "read" "$HOOK_SO" "$PATTERN" "$BS" 1
                else
                    echo -e "${RED}[WARN] CPU Daemon 压缩失败${NC}"
                fi
            else
                echo -e "${RED}[WARN] 测试文件不存在，跳过 CPU hook 对比${NC}"
            fi
        done
    done

    # 打印最终报告
    print_report

    echo ""
    echo -e "${GREEN}全部测试完成！${NC}"
    echo "原始 JSON 数据: /tmp/fio_*.json"
    echo "GPU 采样日志: /tmp/gpu_*.log"
}

main "$@"
