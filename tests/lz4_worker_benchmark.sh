#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/lz4_worker_${RUN_ID}}"
mkdir -p "$RESULT_DIR"

make -C "$PROJECT_DIR" bin/test_lz4_cpu_gpu >/dev/null
"$PROJECT_DIR/bin/test_lz4_cpu_gpu" | tee "$RESULT_DIR/raw.csv"

python3 - "$RESULT_DIR/raw.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv, math, statistics, sys
lines = open(sys.argv[1]).read().splitlines()
rows = list(csv.DictReader(line for line in lines if not line.startswith("logical_bytes=")))
groups = {}
for row in rows:
    groups.setdefault(row["backend"], []).append(float(row["mib_s"]))
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["backend", "n", "mean_mib_s", "stddev_mib_s", "ci95_mib_s"])
    for backend, values in groups.items():
        mean = statistics.mean(values)
        std = statistics.stdev(values) if len(values) > 1 else 0.0
        ci = 1.96 * std / math.sqrt(len(values)) if len(values) > 1 else 0.0
        w.writerow([backend, len(values), f"{mean:.3f}", f"{std:.3f}", f"{ci:.3f}"])
PY

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader | head -1)"
    echo "cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    echo "data=16 MiB deterministic page pattern; same CPU-generated LZ4 blocks"
    echo "repeats=5"
    echo "concurrent_callers=4 (script exits nonzero on mismatch)"
} > "$RESULT_DIR/environment.txt"

echo "[OK] $RESULT_DIR"
