#!/usr/bin/env bash
set -euo pipefail

# Process-scoped Linux perf counters. test_cpu_offload enables the counters only
# after allocation/compression/warmup and disables them immediately after the
# timed steady-state phase. Generic cache-misses are reported honestly; they are
# not labelled as model-specific LLC-load-misses.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/perf_offload_${RUN_ID}}"
TEST_BIN="$PROJECT_DIR/bin/test_cpu_offload"
DURATION="${GPUC_RUNTIME:-10}"
REPEATS="${GPUC_REPEATS:-5}"
WORKERS="${GPUC_BUSINESS_WORKERS:-4}"
DECOMP_CPU="${GPUC_DECOMP_CPU:-0}"
TARGET_MIB_S="${GPUC_TARGET_MIB_S:-4096}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-512}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-128}"
export GPUC_WORKER_CPU="${GPUC_WORKER_CPU:-$DECOMP_CPU}"

make -C "$PROJECT_DIR" bin/test_cpu_offload >/dev/null
mkdir -p "$RESULT_DIR/raw"
{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)"
    echo "duration_s=$DURATION"
    echo "repeats=$REPEATS"
    echo "workset_mib=$WORKSET_MIB"
    echo "batch_blocks=$BATCH_BLOCKS"
    echo "target_mib_s=$TARGET_MIB_S"
    echo "counter_scope=process plus inherited threads, user space, steady-state only"
    echo "cache_event=generic PERF_COUNT_HW_CACHE_MISSES; not exact LLC-load-misses"
} > "$RESULT_DIR/environment.txt"

echo "scenario,repeat,elapsed_s,business_ops_s,decomp_mib_s,cycles,instructions,ipc,cache_references,cache_misses,cache_miss_pct" \
    > "$RESULT_DIR/runs.csv"

scenarios=(baseline cpu gpu)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 3 ))
    for index in 0 1 2; do
        scenario="${scenarios[$(( (index + shift) % 3 ))]}"
        tag="${scenario}_r${repeat}"
        app_output="$RESULT_DIR/raw/${tag}_app.txt"
        counters="$RESULT_DIR/raw/${tag}_counters.csv"
        GPUC_WORKSET_MIB="$WORKSET_MIB" \
        GPUC_BATCH_BLOCKS="$BATCH_BLOCKS" \
        GPUC_PERF_COUNTERS_FILE="$counters" \
            "$TEST_BIN" "$scenario" "$DURATION" "$WORKERS" \
            "$DECOMP_CPU" "$TARGET_MIB_S" > "$app_output"
        python3 - "$scenario" "$repeat" "$app_output" "$counters" \
            "$RESULT_DIR/runs.csv" <<'PY'
import csv
import sys

scenario, repeat, app_path, counter_path, output = sys.argv[1:]
app = next(
    row for row in reversed(list(csv.reader(open(app_path))))
    if len(row) == 25 and row[0] == scenario
)
counter = next(csv.DictReader(open(counter_path)))
cycles = int(counter["cycles"])
instructions = int(counter["instructions"])
refs = int(counter["cache_references"])
misses = int(counter["cache_misses"])
ipc = instructions / cycles if cycles else 0.0
miss_pct = misses * 100.0 / refs if refs else 0.0
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow([
        scenario, repeat, app[1], app[3], app[4], cycles, instructions,
        f"{ipc:.6f}", refs, misses, f"{miss_pct:.6f}",
    ])
print(
    f"[PASS] {scenario:8s} repeat={repeat} "
    f"cycles={cycles} IPC={ipc:.3f} cache-miss={miss_pct:.3f}%"
)
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv
import math
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
metrics = [
    "business_ops_s", "decomp_mib_s", "cycles", "instructions", "ipc",
    "cache_references", "cache_misses", "cache_miss_pct",
]
with open(sys.argv[2], "w", newline="") as f:
    writer = csv.writer(f, lineterminator="\n")
    header = ["scenario", "n"]
    for metric in metrics:
        header += [f"{metric}_mean", f"{metric}_ci95"]
    writer.writerow(header)
    for scenario in ("baseline", "cpu", "gpu"):
        samples = [row for row in rows if row["scenario"] == scenario]
        output = [scenario, len(samples)]
        for metric in metrics:
            values = [float(row[metric]) for row in samples]
            mean = statistics.mean(values)
            ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values))
            output += [f"{mean:.6f}", f"{ci:.6f}"]
        writer.writerow(output)
PY

echo "[OK] process perf experiment complete: $RESULT_DIR"
