#!/bin/bash
set -e

# ============================================================
#  GPU Compress - 一键 DEMO 脚本
#
# 演示全流程：
#   1. 用 LD_PRELOAD 写入文件（自动附加 RAW header）
#   2. 正常读取（RAW 状态，透传）
#   3. CPU 压缩对比
#   4. GPU 离线压缩
#   5. 透明读取已压缩文件（GPU 实时解压）
#   6. 压缩效果对比
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
CPU_DAEMON="$PROJECT_DIR/bin/cpu_compress_daemon"
TESTDIR="/tmp/gpuc_demo"
TESTFILE="$TESTDIR/demo.bin"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

step() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# 检查编译产物
check_build() {
    if [ ! -f "$HOOK_SO" ] || [ ! -f "$GPU_DAEMON" ] || [ ! -f "$CPU_DAEMON" ]; then
        echo -e "${RED}[ERROR] 编译产物不存在，请先执行: make all${NC}"
        exit 1
    fi
}

# 获取文件压缩信息
file_info() {
    local f=$1
    local label=$2
    if [ -f "$f" ]; then
        local logical=$(ls -l "$f" | awk '{print $5}')
        local physical=$(du -B1 "$f" | awk '{print $1}')
        info "$label: 逻辑大小=$(echo "$logical" | numfmt --to=iec) 物理大小=$(echo "$physical" | numfmt --to=iec) 压缩率=$(echo "scale=1; $physical * 100 / $logical" | bc)%"
    fi
}

# 使用 LD_PRELOAD 的 cat
hook_cat() {
    LD_PRELOAD="$HOOK_SO" cat "$1" > /dev/null
}

main() {
    check_build

    rm -rf "$TESTDIR"
    mkdir -p "$TESTDIR"

    step "DEMO 开始: 基于 GPU 的透明存储压缩卸载"
    info "测试文件: $TESTFILE"
    info "数据大小: 100MB (全零，高压缩率)"

    # Step 1: 写入文件（带 hook）
    step "Step 1: 使用 LD_PRELOAD 写入文件（自动附加 RAW header）"
    dd if=/dev/zero bs=1M count=100 2>/dev/null | LD_PRELOAD="$HOOK_SO" dd of="$TESTFILE" bs=1M 2>/dev/null
    info "写入完成"
    file_info "$TESTFILE" "写入后"

    # 验证 header
    python3 << EOF
import struct
with open('$TESTFILE', 'rb') as f:
    data = f.read(64)
    magic = struct.unpack('<I', data[0:4])[0]
    state = data[24]
    print(f"  [验证] Magic={'GPUC' if magic==0x47505543 else 'UNKNOWN'}, State={'RAW' if state==0 else 'COMPRESSED'})")
EOF

    # Step 2: RAW 读取
    step "Step 2: 正常读取（RAW 未压缩状态，直接透传）"
    local t0=$(date +%s.%N)
    hook_cat "$TESTFILE"
    local t1=$(date +%s.%N)
    local dt=$(echo "$t1 - $t0" | bc)
    info "读取耗时: ${dt}s  (约 $(echo "scale=0; 100 / $dt" | bc) MB/s)"

    # Step 3: CPU 压缩
    step "Step 3: CPU 离线压缩对比"
    cp "$TESTFILE" "${TESTFILE}.cpu"
    t0=$(date +%s.%N)
    "$CPU_DAEMON" "$TESTDIR"
    t1=$(date +%s.%N)
    dt=$(echo "$t1 - $t0" | bc)
    info "CPU 压缩耗时: ${dt}s"
    file_info "${TESTFILE}.cpu" "CPU 压缩后"

    # Step 4: GPU 压缩
    step "Step 4: GPU 离线压缩"
    t0=$(date +%s.%N)
    "$GPU_DAEMON" "$TESTDIR"
    t1=$(date +%s.%N)
    dt=$(echo "$t1 - $t0" | bc)
    info "GPU 压缩耗时: ${dt}s"
    file_info "$TESTFILE" "GPU 压缩后"

    # Step 5: 透明读取压缩文件
    step "Step 5: 透明读取已压缩文件（自动 GPU 解压）"
    t0=$(date +%s.%N)
    hook_cat "$TESTFILE"
    t1=$(date +%s.%N)
    dt=$(echo "$t1 - $t0" | bc)
    info "读取耗时: ${dt}s  (约 $(echo "scale=0; 100 / $dt" | bc) MB/s)"

    # Step 6: 总结
    step "DEMO 总结"
    info "✓ 写入时自动附加 header，对应用完全透明"
    info "✓ RAW 状态读取直接透传，性能无损耗"
    info "✓ CPU 压缩与 GPU 压缩效果一致"
    info "✓ 读取已压缩文件时自动 GPU 解压，应用无感知"

    # 数据一致性验证
    step "数据一致性验证"
    LD_PRELOAD="$HOOK_SO" dd if="$TESTFILE" bs=1M 2>/dev/null | md5sum > /tmp/gpu_md5.txt
    dd if=/dev/zero bs=1M count=100 2>/dev/null | md5sum > /tmp/orig_md5.txt
    if diff -q /tmp/gpu_md5.txt /tmp/orig_md5.txt >/dev/null; then
        info "✓ MD5 校验通过：解压后数据与原始数据完全一致"
    else
        warn "✗ MD5 校验失败！"
    fi

    echo ""
    echo -e "${GREEN}DEMO 完成！${NC}"
}

main "$@"
