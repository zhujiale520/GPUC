#!/usr/bin/env bash
set -euo pipefail

# Oracle Vdbench is license-gated and is not redistributed by this repository.
# Install it after accepting Oracle's license, then set VDBENCH_HOME.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/vdbench_${RUN_ID}}"
VDBENCH="${VDBENCH_HOME:-}/vdbench"
SIZE="${GPUC_SIZE:-256m}"
ELAPSED="${GPUC_RUNTIME:-10}"
REPEATS="${GPUC_REPEATS:-5}"
TEST_DIR="$(mktemp -d /tmp/gpuc-vdbench-XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT
mkdir -p "$RESULT_DIR"

{
    echo "official_download=https://www.oracle.com/downloads/server-storage/vdbench-downloads.html"
    echo "license=Oracle Technology Network license acceptance required"
    echo "VDBENCH_HOME=${VDBENCH_HOME:-unset}"
    echo "java=$(command -v java || echo unavailable)"
    echo "vdbench=$([[ -x "$VDBENCH" ]] && echo "$VDBENCH" || echo unavailable)"
} > "$RESULT_DIR/capability.txt"

if [[ -z "${VDBENCH_HOME:-}" || ! -x "$VDBENCH" ]]; then
    echo "SKIP: install licensed Oracle Vdbench and set VDBENCH_HOME." \
        | tee "$RESULT_DIR/SKIPPED.txt"
    exit 2
fi
command -v java >/dev/null || {
    echo "SKIP: Java runtime is required." | tee "$RESULT_DIR/SKIPPED.txt"
    exit 2
}

HOOK="$PROJECT_DIR/bin/libgpuhook.so"
BASE="$TEST_DIR/baseline.bin"
RAW="$TEST_DIR/hook_raw.bin"
dd if=/dev/zero of="$BASE" bs=1M count="${SIZE%m}" status=none
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$BASE" "$RAW"

echo "scenario,workload,repeat,output_dir" > "$RESULT_DIR/runs.csv"
for repeat in $(seq 1 "$REPEATS"); do
    for workload in seq_read random_read mixed_rw; do
        for scenario in baseline hook_raw; do
            path="$BASE"; preload=()
            [[ "$scenario" == hook_raw ]] &&
                { path="$RAW"; preload=(env LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1); }
            par="$RESULT_DIR/${scenario}_${workload}_r${repeat}.par"
            sed -e "s|@LUN@|$path|g" -e "s|@SIZE@|$SIZE|g" \
                -e "s|@ELAPSED@|$ELAPSED|g" \
                "$PROJECT_DIR/tests/vdbench/${workload}.par" > "$par"
            outdir="$RESULT_DIR/${scenario}_${workload}_r${repeat}"
            "${preload[@]}" "$VDBENCH" -f "$par" -o "$outdir"
            echo "$scenario,$workload,$repeat,$outdir" >> "$RESULT_DIR/runs.csv"
        done
    done
done

echo "[OK] $RESULT_DIR"
