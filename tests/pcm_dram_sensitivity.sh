#!/usr/bin/env bash
set -euo pipefail

# Representative whole-system Intel PCM points for the decompression
# throughput/compressibility sensitivity matrix. This wrapper intentionally
# re-measures baseline for every point because whole-system idle traffic can
# drift over the approximately ten-minute run.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/pcm_dram_sensitivity_${RUN_ID}}"
PCM_GROUPS="${GPUC_PCM_GROUPS:-1024:0 2048:50 4096:100}"
RUNTIME="${GPUC_RUNTIME:-10}"
REPEATS="${GPUC_REPEATS:-5}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-512}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-128}"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Intel PCM sensitivity requires root." >&2
    echo "Run this script through sudo env; do not place a password in a script." >&2
    exit 2
fi
for value in "$RUNTIME" "$REPEATS" "$WORKSET_MIB" "$BATCH_BLOCKS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: runtime, repeats, workset and batch must be positive integers." >&2
        exit 2
    }
done
for group in $PCM_GROUPS; do
    [[ "$group" =~ ^([1-9][0-9]*):([0-9]+)$ ]] || {
        echo "ERROR: invalid group '$group'; expected target_mib_s:compressible_pct." >&2
        exit 2
    }
    (( BASH_REMATCH[2] <= 100 )) || {
        echo "ERROR: invalid compressible percentage in '$group'." >&2
        exit 2
    }
done

mkdir -p "$RESULT_DIR/groups"
restore_owner() {
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown -R "$SUDO_UID:$SUDO_GID" "$RESULT_DIR" 2>/dev/null || true
    fi
}
trap restore_owner EXIT

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "groups=$PCM_GROUPS"
    echo "runtime_s=$RUNTIME"
    echo "repeats=$REPEATS"
    echo "workset_mib=$WORKSET_MIB"
    echo "batch_blocks=$BATCH_BLOCKS"
    echo "method=each point includes its own rotated baseline/cpu/gpu five-round PCM run"
    echo "scope=whole-system IMC bandwidth; only complete steady-state 1s intervals"
} > "$RESULT_DIR/environment.txt"

for group in $PCM_GROUPS; do
    target="${group%%:*}"
    pct="${group##*:}"
    child="$RESULT_DIR/groups/t${target}_p${pct}"
    echo "[RUN] target=$target MiB/s compressible=$pct%"
    GPUC_RESULT_DIR="$child" \
    GPUC_RUNTIME="$RUNTIME" GPUC_REPEATS="$REPEATS" \
    GPUC_TARGET_MIB_S="$target" GPUC_COMPRESSIBLE_PCT="$pct" \
    GPUC_WORKSET_MIB="$WORKSET_MIB" GPUC_BATCH_BLOCKS="$BATCH_BLOCKS" \
    GPUC_DECOMP_CPU="${GPUC_DECOMP_CPU:-0}" \
    GPUC_WORKER_CPU="${GPUC_WORKER_CPU:-${GPUC_DECOMP_CPU:-0}}" \
    bash "$PROJECT_DIR/tests/pcm_dram_offload.sh"
done

python3 - "$RESULT_DIR" $PCM_GROUPS <<'PY'
import csv
import math
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
groups = []
all_rows = []
for item in sys.argv[2:]:
    target, pct = map(int, item.split(":"))
    rows = list(csv.DictReader(open(root / "groups" / f"t{target}_p{pct}" / "runs.csv")))
    for row in rows:
        row = {"target_mib_s": str(target), **row}
        all_rows.append(row)
    groups.append((target, pct, rows))

fields = ["target_mib_s", *[x for x in all_rows[0] if x != "target_mib_s"]]
with open(root / "runs.csv", "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields, lineterminator="\n")
    w.writeheader()
    w.writerows(all_rows)

metrics = ["dram_read_mb_s", "dram_write_mb_s", "dram_total_mb_s",
           "business_ops_s", "decomp_mib_s", "maxrss_kib"]
with open(root / "summary.csv", "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["target_mib_s", "requested_compressible_pct", "scenario", "n"] +
               [x for m in metrics for x in (f"{m}_mean", f"{m}_ci95")])
    for target, pct, rows in groups:
        for scenario in ("baseline", "cpu", "gpu"):
            selected = [r for r in rows if r["scenario"] == scenario]
            out = [target, pct, scenario, len(selected)]
            for metric in metrics:
                values = [float(r[metric]) for r in selected]
                mean = statistics.mean(values)
                ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values)) if len(values) > 1 else 0
                out += [f"{mean:.6f}", f"{ci:.6f}"]
            w.writerow(out)

with open(root / "conclusions.txt", "w") as f:
    for target, pct, rows in groups:
        avg = lambda scenario, metric: statistics.mean(
            float(r[metric]) for r in rows if r["scenario"] == scenario)
        c, g = avg("cpu", "dram_total_mb_s"), avg("gpu", "dram_total_mb_s")
        ca, ga = avg("cpu", "decomp_mib_s") / target * 100, avg("gpu", "decomp_mib_s") / target * 100
        f.write(f"target={target} pct={pct} cpu_dram={c:.2f} gpu_dram={g:.2f} "
                f"gpu_vs_cpu={(g / c - 1) * 100:+.2f}% "
                f"cpu_attain={ca:.2f}% gpu_attain={ga:.2f}%\n")
PY

sha256sum "$PROJECT_DIR/tests/test_cpu_offload.cpp" \
    "$PROJECT_DIR/tests/pcm_dram_offload.sh" \
    "$PROJECT_DIR/tests/pcm_dram_sensitivity.sh" \
    "$PROJECT_DIR/src/gpu_lz4.cu" "$PROJECT_DIR/src/cpu_lz4.c" \
    > "$RESULT_DIR/SOURCE_MANIFEST.sha256"
echo "[OK] PCM DRAM sensitivity complete: $RESULT_DIR"
