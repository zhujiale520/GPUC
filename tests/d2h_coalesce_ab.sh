#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/d2h_coalesce_${RUN_ID}}"
DURATION="${GPUC_RUNTIME:-5}"
REPEATS="${GPUC_REPEATS:-5}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-512}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-128}"
TARGET_MIB_S="${GPUC_TARGET_MIB_S:-0}"
mkdir -p "$RESULT_DIR/raw"
make -C "$PROJECT_DIR" bin/test_cpu_offload >/dev/null
{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)"
    echo "cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    echo "duration_s=$DURATION"
    echo "repeats=$REPEATS"
    echo "workset_mib=$WORKSET_MIB"
    echo "batch_blocks=$BATCH_BLOCKS"
    echo "target_mib_s=$TARGET_MIB_S"
    echo "host_workset=pageable for worksets larger than 64 MiB"
} > "$RESULT_DIR/environment.txt"

echo "mode,repeat,decomp_mib_s,h2d_ms,kernel_ms,d2h_ms,total_ms,worker_cpu_s" \
    > "$RESULT_DIR/runs.csv"
for repeat in $(seq 1 "$REPEATS"); do
    for mode in legacy coalesced; do
        coalesce=1
        [[ "$mode" == legacy ]] && coalesce=0
        output="$RESULT_DIR/raw/${mode}_r${repeat}.txt"
        GPUC_WORKSET_MIB="$WORKSET_MIB" GPUC_BATCH_BLOCKS="$BATCH_BLOCKS" \
        GPUC_D2H_COALESCE="$coalesce" \
            "$PROJECT_DIR/bin/test_cpu_offload" gpu "$DURATION" 0 0 \
            "$TARGET_MIB_S" > "$output"
        python3 - "$mode" "$repeat" "$output" "$RESULT_DIR/runs.csv" <<'PY'
import csv
import sys
mode, repeat, source, target = sys.argv[1:]
row = next(row for row in csv.reader(open(source)) if len(row) == 25)
with open(target, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow([
        mode, repeat, row[4], row[17], row[18], row[19], row[21],
        f"{float(row[22]) + float(row[23]):.6f}",
    ])
print(f"[PASS] {mode:9s} repeat={repeat} throughput={float(row[4]):.1f} MiB/s d2h={float(row[19]):.3f} ms")
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv, math, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
metrics = ["decomp_mib_s", "h2d_ms", "kernel_ms", "d2h_ms", "total_ms", "worker_cpu_s"]
with open(sys.argv[2], "w", newline="") as f:
    writer = csv.writer(f, lineterminator="\n")
    writer.writerow(["mode", "n", *sum(([f"{m}_mean", f"{m}_ci95"] for m in metrics), [])])
    for mode in ("legacy", "coalesced"):
        samples = [r for r in rows if r["mode"] == mode]
        out = [mode, len(samples)]
        for metric in metrics:
            values = [float(r[metric]) for r in samples]
            out += [f"{statistics.mean(values):.6f}",
                    f"{1.96 * statistics.stdev(values) / math.sqrt(len(values)):.6f}"]
        writer.writerow(out)
PY
echo "[OK] D2H A/B complete: $RESULT_DIR"
