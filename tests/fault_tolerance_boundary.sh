#!/bin/bash
set -e

# ============================================================
#  Fault Tolerance & Boundary Test
# ============================================================
# 覆盖场景：
#   1. daemon 压缩时应用并发读/写
#   2. 显存不足时 GPU 读 fallback / 报错
#   3. 磁盘空间不足时正确返回 ENOSPC
#   4. 进程崩溃（kill -9）后文件一致性
#   5. fsync 语义验证
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="/tmp/gpuc_fault_tolerance_$$"
RESULTDIR="/tmp/gpuc_fault_tolerance_results_$$"

mkdir -p "$TESTDIR" "$RESULTDIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

RESULT_LOG="$RESULTDIR/results.log"
echo "Fault Tolerance & Boundary Test Results" > "$RESULT_LOG"
echo "========================================" >> "$RESULT_LOG"

PASS=0
FAIL=0

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

# ----------------------------------------------------------
#  1. daemon 压缩时应用并发读/写
# ----------------------------------------------------------
test_daemon_concurrent() {
    echo ""
    echo -e "${YELLOW}### 1. daemon 压缩时应用并发读/写 ###${NC}"
    local testfile="$TESTDIR/daemon_concurrent.bin"
    rm -f "$testfile"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if=/dev/zero of="$testfile" bs=1M count=256 status=none

    # 后台启动 daemon 压缩
    "$GPU_DAEMON" "$TESTDIR" >/dev/null 2>&1 &
    local daemon_pid=$!

    # 同时用 hook 读取和写入另一个文件
    local readfile="$TESTDIR/daemon_read.bin"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if=/dev/zero of="$readfile" bs=1M count=64 status=none

    local ok=1
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        fio --name=concurrent_read --filename="$readfile" --size=64M --bs=128k --rw=read \
            --direct=1 --ioengine=sync --runtime=10 --time_based --numjobs=4 --group_reporting \
            --unlink=0 --buffer_pattern=0x00 --output-format=json > "$RESULTDIR/daemon_concurrent.json" 2>/dev/null || ok=0

    wait $daemon_pid 2>/dev/null || true

    if [ $ok -eq 1 ]; then
        pass "daemon 压缩期间应用并发读/写未崩溃"
    else
        fail "daemon 压缩期间应用并发读/写失败"
    fi
}

# ----------------------------------------------------------
#  2. 显存不足时 fallback / 报错
# ----------------------------------------------------------
test_oom_gpu() {
    echo ""
    echo -e "${YELLOW}### 2. 显存不足时 GPU 读行为 ###${NC}"
    local testfile="$TESTDIR/oom_gpu.bin"
    rm -f "$testfile"

    # 使用 test_hook 生成可验证的混合可压缩数据
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        "$PROJECT_DIR/bin/test_hook" writemixed "$testfile" 262144
    "$GPU_DAEMON" "$TESTDIR" >/dev/null 2>&1

    # 编译一个占用几乎全部 GPU 显存的 helper
    local oom_helper="$PROJECT_DIR/bin/oom_gpu_helper"
    cat > /tmp/oom_gpu_helper.cu << 'EOF'
#include <cuda_runtime.h>
#include <cstdio>
#include <unistd.h>
int main() {
    size_t free = 0, total = 0;
    cudaMemGetInfo(&free, &total);
    // 分配 99.5% 剩余显存，使后续 CUDA context 创建失败
    size_t alloc = (size_t)(free * 0.995);
    void *p = nullptr;
    cudaError_t err = cudaMalloc(&p, alloc);
    if (err != cudaSuccess) {
        printf("alloc failed: %s\n", cudaGetErrorString(err));
        return 1;
    }
    printf("allocated %zu bytes (%.1f%% of free)\n", alloc, alloc * 100.0 / free);
    cudaDeviceSynchronize();
    sleep(10);
    cudaFree(p);
    return 0;
}
EOF
    if ! nvcc -arch=sm_70 -Wno-deprecated-gpu-targets /tmp/oom_gpu_helper.cu -o "$oom_helper" 2>/dev/null; then
        echo -e "${BLUE}无法编译 OOM helper，跳过此项${NC}"
        echo "SKIP: GPU OOM fallback test (nvcc failed)" >> "$RESULT_LOG"
        return
    fi

    local ok=0
    "$oom_helper" >/dev/null 2>&1 &
    local oom_pid=$!
    sleep 2

    # 在 GPU 显存几乎耗尽时读取压缩文件并验证内容
    if LD_PRELOAD="$HOOK_SO" "$PROJECT_DIR/bin/test_hook" readmixed "$testfile" 262144 > "$RESULTDIR/oom_gpu.txt" 2>&1; then
        ok=1
    fi

    kill $oom_pid 2>/dev/null || true
    wait $oom_pid 2>/dev/null || true

    if [ $ok -eq 1 ]; then
        pass "显存不足时 GPU 读正确 fallback CPU，数据验证通过"
    else
        echo "OOM read output:"
        cat "$RESULTDIR/oom_gpu.txt" || true
        fail "显存不足时读压缩文件失败或数据不一致"
    fi
}

# ----------------------------------------------------------
#  3. 磁盘空间不足时正确返回 ENOSPC
# ----------------------------------------------------------
test_enospc() {
    echo ""
    echo -e "${YELLOW}### 3. 磁盘空间不足 ENOSPC ###${NC}"
    local smallfs="$TESTDIR/smallfs"
    mkdir -p "$smallfs"

    # 创建 16 MB tmpfs
    if ! mountpoint -q "$smallfs"; then
        mount -t tmpfs -o size=16M tmpfs "$smallfs" 2>/dev/null || {
            echo -e "${BLUE}无法 mount tmpfs（可能需要 root），跳过此项${NC}"
            echo "SKIP: ENOSPC test (no root)" >> "$RESULT_LOG"
            return
        }
    fi

    # 填充到接近满
    dd if=/dev/zero of="$smallfs/fill.bin" bs=1M count=14 status=none 2>/dev/null || true

    # 尝试用 hook 创建文件，应失败
    local ret=0
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if=/dev/zero of="$smallfs/nospace.bin" bs=1M count=8 status=none 2>/dev/null || ret=$?

    umount "$smallfs" 2>/dev/null || true

    if [ $ret -ne 0 ]; then
        pass "磁盘满时 hook 写文件正确失败"
    else
        fail "磁盘满时 hook 写文件未失败（可能空间仍足够）"
    fi
}

# ----------------------------------------------------------
#  4. 进程崩溃（kill -9）后文件一致性
# ----------------------------------------------------------
test_crash_consistency() {
    echo ""
    echo -e "${YELLOW}### 4. 进程崩溃后文件一致性 ###${NC}"
    local testfile="$TESTDIR/crash_consistency.bin"
    rm -f "$testfile"

    # 启动后台进程写文件
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 bash -c "
        python3 - << PY
import time, os
with open('$testfile', 'wb') as f:
    for i in range(1000):
        f.write(b'A' * 65536)
        if i % 100 == 0:
            f.flush()
            os.fsync(f.fileno())
        time.sleep(0.01)
PY
" &
    local writer_pid=$!

    sleep 2
    kill -9 $writer_pid 2>/dev/null || true
    wait $writer_pid 2>/dev/null || true

    # 检查文件是否能被正常读取（不要求内容完整，但不能让后续 open 崩溃）
    local ok=0
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 \
        python3 -c "
import os
try:
    size = os.path.getsize('$testfile')
    with open('$testfile', 'rb') as f:
        f.read(min(size, 65536))
    print('ok')
except Exception as e:
    print('fail', e)
" > "$RESULTDIR/crash_consistency.txt" 2>&1 && ok=1

    if [ $ok -eq 1 ] && grep -q "ok" "$RESULTDIR/crash_consistency.txt"; then
        pass "进程崩溃后文件可被正常 open/read"
    else
        fail "进程崩溃后文件无法正常读取"
    fi
}

# ----------------------------------------------------------
#  5. fsync 语义验证
# ----------------------------------------------------------
test_fsync_semantics() {
    echo ""
    echo -e "${YELLOW}### 5. fsync 语义验证 ###${NC}"
    local testfile="$TESTDIR/fsync_test.bin"
    rm -f "$testfile"

    local data="$(python3 -c 'print("X" * 1048576, end="")')"

    # 用 hook 写文件并 fsync
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 python3 - << PYEOF
import os
with open('$testfile', 'wb') as f:
    f.write(b'$data')
    f.flush()
    os.fsync(f.fileno())
PYEOF

    # 重新打开读取
    local readback=""
    readback=$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 python3 - << PYEOF
with open('$testfile', 'rb') as f:
    d = f.read()
print(len(d), d[:10].hex())
PYEOF
)

    if echo "$readback" | grep -q "1048576 58585858585858585858"; then
        pass "fsync 后数据可正确读回"
    else
        fail "fsync 后数据读回不一致"
    fi
}

# ----------------------------------------------------------
#  主流程
# ----------------------------------------------------------
echo "========================================"
echo "  Fault Tolerance & Boundary Test"
echo "========================================"
echo "测试目录: $TESTDIR"
echo "========================================"

test_daemon_concurrent
test_oom_gpu
test_enospc
test_crash_consistency
test_fsync_semantics

echo ""
echo "========================================"
echo "       汇总"
echo "========================================"
echo -e "${GREEN}PASS: $PASS${NC}"
echo -e "${RED}FAIL: $FAIL${NC}"
echo ""
echo "详细日志: $RESULT_LOG"

rm -rf "$TESTDIR"
