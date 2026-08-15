#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="${GPUC_TEST_ROOT:-$PROJECT_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/domestic_poc_$STAMP}"
WORK_DIR="$(mktemp -d "$TEST_ROOT/gpuc-domestic-XXXXXX")"
REQUIRE_GPU=0

if [ "${1:-}" = "--require-gpu" ]; then
    REQUIRE_GPU=1
elif [ "$#" -gt 0 ]; then
    echo "Usage: $0 [--require-gpu]" >&2
    exit 2
fi

cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT
mkdir -p "$RESULT_DIR"

exec > >(tee "$RESULT_DIR/run.log") 2>&1

echo "=== GPUC 国产平台最小可行性验证 ==="
echo "result_dir=$RESULT_DIR"
echo "timestamp_utc=$STAMP"
echo "arch=$(uname -m)"
echo "kernel=$(uname -r)"
lscpu | grep -E 'Architecture|Vendor ID|Model name|Socket|Core|NUMA' > "$RESULT_DIR/cpu.txt" || true
lspci -nnk > "$RESULT_DIR/lspci.txt" || true
lsmod > "$RESULT_DIR/lsmod.txt" || true

echo "[1/3] Build and test the AArch64 CPU fallback"
make -C "$PROJECT_DIR" cpu-only
GPUC_TEST_ROOT="$TEST_ROOT" make -C "$PROJECT_DIR" smoke-test

echo "[2/3] End-to-end CPU compression and transparent read"
MANAGED="$WORK_DIR/managed.bin"
LD_PRELOAD="$PROJECT_DIR/bin/libcpuhook.so" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_hook" write "$MANAGED" 16777216
SOURCE_SHA="$(python3 -c 'import hashlib; print(hashlib.sha256(bytes(range(256)) * (16777216 // 256)).hexdigest())')"
"$PROJECT_DIR/bin/cpu_compress_daemon" "$WORK_DIR"
# openEuler coreutils sha256sum may use a libc-internal open path that bypasses
# symbol interposition.  Keep the managed reader explicit and hash stdout.
LOGICAL_SHA="$(LD_PRELOAD="$PROJECT_DIR/bin/libcpuhook.so" GPUCOMPRESS_QUIET=1 \
    dd if="$MANAGED" of=/dev/stdout bs=1M status=none | sha256sum | awk '{print $1}')"
if [ "$SOURCE_SHA" != "$LOGICAL_SHA" ]; then
    echo "[FAIL] CPU logical SHA mismatch"
    exit 1
fi
LD_PRELOAD="$PROJECT_DIR/bin/libcpuhook.so" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_hook" read "$MANAGED" 16777216
printf 'cpu_build=PASS\ncpu_smoke=PASS\ncpu_e2e_sha=PASS\nsource_sha256=%s\n' "$SOURCE_SHA" \
    > "$RESULT_DIR/summary.txt"
echo "[PASS] Kunpeng/AArch64 CPU path: build + smoke + logical SHA"

echo "[3/3] Probe the CoreX SGLZ GPU path"
GPU_REASON=""
if ! command -v ixsmi >/dev/null 2>&1; then
    GPU_REASON="ixsmi not found"
elif ! ixsmi >/dev/null 2>&1; then
    GPU_REASON="CoreX GPU is not accessible (check device-node mapping)"
elif ! make -C "$PROJECT_DIR" corex; then
    GPU_REASON="CoreX CUDA compiler is incomplete or unavailable"
else
    if "$PROJECT_DIR/bin/test_compress"; then
        echo "gpu_sglz_unit=PASS" >> "$RESULT_DIR/summary.txt"
        echo "[PASS] CoreX SGLZ GPU unit test"
        exit 0
    fi
    GPU_REASON="CoreX SGLZ unit test failed"
fi

printf 'gpu_sglz_unit=BLOCKED\ngpu_reason=%s\n' "$GPU_REASON" >> "$RESULT_DIR/summary.txt"
echo "[BLOCKED] $GPU_REASON"
if [ "$REQUIRE_GPU" -eq 1 ]; then
    exit 3
fi
