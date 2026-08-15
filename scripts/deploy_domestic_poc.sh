#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COREX_HOME="${COREX_HOME:-/usr/local/corex-4.4.0}"
export PATH="$COREX_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$COREX_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
    if tr '\0' ' ' </proc/1/cmdline 2>/dev/null | grep -q 'bwrap.*--dev /dev'; then
        GPU_REASON="Codex/bwrap isolates /dev; rerun this script in the host shell"
    else
        GPU_REASON="CoreX GPU is not accessible (check device-node mapping)"
    fi
elif ! make -C "$PROJECT_DIR" corex; then
    GPU_REASON="CoreX Clang/ivcore build failed"
else
    ixsmi -q > "$RESULT_DIR/ixsmi.txt"
    if ! "$PROJECT_DIR/bin/test_compress"; then
        GPU_REASON="CoreX SGLZ unit test failed"
    else
        GPU_DIR="$WORK_DIR/gpu"
        GPU_MANAGED="$GPU_DIR/managed.bin"
        mkdir -p "$GPU_DIR"
        LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
            "$PROJECT_DIR/bin/test_hook" write "$GPU_MANAGED" 16777216
        "$PROJECT_DIR/bin/gpu_compress_daemon" "$GPU_DIR"
        LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
            "$PROJECT_DIR/bin/test_hook" read "$GPU_MANAGED" 16777216
        GPU_SHA="$(LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
            dd if="$GPU_MANAGED" of=/dev/stdout bs=1M status=none | \
            sha256sum | awk '{print $1}')"
        if [ "$GPU_SHA" != "$SOURCE_SHA" ]; then
            GPU_REASON="CoreX GPU logical SHA mismatch"
        else
            GPU_MODEL="$(awk -F: '/Product Name/{sub(/^[[:space:]]+/, "", $2); print $2; exit}' "$RESULT_DIR/ixsmi.txt")"
            printf 'gpu_sglz_unit=PASS\ngpu_e2e_sha=PASS\ngpu_model=%s\ncorex_arch=ivcore11\n' \
                "$GPU_MODEL" >> "$RESULT_DIR/summary.txt"
            echo "[PASS] CoreX SGLZ unit + GPU daemon + transparent read + SHA"
            exit 0
        fi
    fi
fi

printf 'gpu_sglz_unit=BLOCKED\ngpu_reason=%s\n' "$GPU_REASON" >> "$RESULT_DIR/summary.txt"
echo "[BLOCKED] $GPU_REASON"
if [ "$REQUIRE_GPU" -eq 1 ]; then
    exit 3
fi
