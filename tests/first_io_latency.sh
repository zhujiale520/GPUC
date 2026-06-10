#!/bin/bash
set -e

# ============================================================
#  First-I/O Latency — Hook lazy init 首次 I/O 惩罚测试
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_firstio_$$"
mkdir -p "$TESTDIR"

# 确保编译产物
if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ] || [ ! -f "$PROJECT_DIR/bin/test_hook" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

TESTFILE="$TESTDIR/latency.bin"
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" "$PROJECT_DIR/bin/test_hook" write "$TESTFILE" 1048576 >/dev/null 2>&1
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1

echo "========================================"
echo "  First-I/O Latency 测试"
echo "========================================"
echo ""

python3 << EOF
import os, subprocess, time, statistics

proj = "$PROJECT_DIR"
testfile = "$TESTFILE"
sizes = [4096, 131072, 1048576]
reps = 10

def run_read(size, env_extra):
    env = {**os.environ, "LD_PRELOAD": f"{proj}/bin/libgpuhook.so", "GPUCOMPRESS_QUIET": "1"}
    env.update(env_extra)
    t0 = time.perf_counter()
    subprocess.run([f"{proj}/bin/test_hook", "read", testfile, str(size)],
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    t1 = time.perf_counter()
    return (t1 - t0) * 1e6

def warm_median(size):
    env = {**os.environ, "LD_PRELOAD": f"{proj}/bin/libgpuhook.so", "GPUCOMPRESS_QUIET": "1"}
    # 先预热一次
    subprocess.run([f"{proj}/bin/test_hook", "read", testfile, str(size)],
                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    times = []
    for _ in range(reps):
        t0 = time.perf_counter()
        subprocess.run([f"{proj}/bin/test_hook", "read", testfile, str(size)],
                       env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        t1 = time.perf_counter()
        times.append((t1 - t0) * 1e6)
    return statistics.median(times)

print(f"{'Size':>10} {'GPU-first(us)':>16} {'CPU-first(us)':>16} {'GPU-warm(us)':>16} {'Ratio':>10}")
print("-" * 75)

for size in sizes:
    gpu_first = [run_read(size, {}) for _ in range(reps)]
    cpu_first = [run_read(size, {"CUDA_VISIBLE_DEVICES": ""}) for _ in range(reps)]
    gpu_warm = warm_median(size)
    ratio = statistics.median(gpu_first) / max(gpu_warm, 1.0)
    print(f"{size:>10} {statistics.median(gpu_first):>16.0f} {statistics.median(cpu_first):>16.0f} {gpu_warm:>16.0f} {ratio:>10.1f}x")
EOF
