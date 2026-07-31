#!/usr/bin/env bash
set -euo pipefail

# Unthrottled CPU liblz4 vs GPU nvCOMP batched LZ4 compression across a
# deterministic compressibility gradient.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/lz4_compress_sensitivity_${RUN_ID}}"
BENCH="$PROJECT_DIR/bin/benchmark_lz4_compress"
RUNTIME="${GPUC_RUNTIME:-5}"
REPEATS="${GPUC_REPEATS:-5}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-512}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-32}"
PCTS="${GPUC_COMPRESSIBLE_PCTS:-0 50 100}"

for value in "$RUNTIME" "$REPEATS" "$WORKSET_MIB" "$BATCH_BLOCKS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid positive integer: $value" >&2; exit 2; }
done
for value in $PCTS; do
    [[ "$value" =~ ^[0-9]+$ ]] && (( value <= 100 )) || {
        echo "ERROR: invalid compressible percentage: $value" >&2; exit 2
    }
done

make -C "$PROJECT_DIR" bin/benchmark_lz4_compress >/dev/null
mkdir -p "$RESULT_DIR/raw"
{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader | head -1)"
    echo "runtime_s=$RUNTIME"
    echo "repeats=$REPEATS"
    echo "workset_mib=$WORKSET_MIB"
    echo "block_kib=128"
    echo "batch_blocks=$BATCH_BLOCKS"
    echo "requested_compressible_pcts=$PCTS"
    echo "target_mib_s=0 (unthrottled peak)"
    echo "data=deterministic 4 KiB repeated-byte/pseudo-random page mixture"
    echo "gpu_energy_scope=board power sampled by nvidia-smi, including idle board power"
} > "$RESULT_DIR/environment.txt"

echo "scenario,requested_compressible_pct,repeat,elapsed_s,mib_s,logical_bytes,stored_bytes,ratio,user_s,sys_s,cpu_cores,maxrss_kib,batches,checksum,gpu_util_pct,gpu_power_w,gpu_power_max_w" \
    > "$RESULT_DIR/runs.csv"

sampler_pid=""
cleanup_sampler() {
    if [[ -n "$sampler_pid" ]]; then
        kill "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
        sampler_pid=""
    fi
}
trap cleanup_sampler EXIT

run_one() {
    local scenario=$1 pct=$2 repeat=$3 backend
    case "$scenario" in cpu) backend=cpu ;; gpu_batch) backend=gpu ;; *) exit 2 ;; esac
    local tag="${scenario}_p${pct}_r${repeat}"
    local app="$RESULT_DIR/raw/${tag}_app.csv"
    local gpu="$RESULT_DIR/raw/${tag}_gpu.csv"
    nvidia-smi --query-gpu=utilization.gpu,power.draw \
        --format=csv,noheader,nounits --loop-ms=200 > "$gpu" 2>/dev/null &
    sampler_pid=$!
    GPUC_COMPRESSIBLE_PCT="$pct" GPUC_TARGET_MIB_S=0 \
        "$BENCH" "$backend" "$RUNTIME" "$WORKSET_MIB" "$BATCH_BLOCKS" > "$app"
    cleanup_sampler
    python3 - "$scenario" "$pct" "$repeat" "$app" "$gpu" "$RESULT_DIR/runs.csv" <<'PY'
import csv
import sys

scenario, pct, repeat, app_path, gpu_path, output = sys.argv[1:]
rows = [r for r in csv.reader(open(app_path)) if len(r) == 16]
if not rows: raise SystemExit(f"missing benchmark row: {app_path}")
r = rows[-1]
samples = []
for row in csv.reader(open(gpu_path, errors="replace")):
    try: samples.append((float(row[0]), float(row[1])))
    except (ValueError, IndexError): pass
if not samples: raise SystemExit(f"missing GPU samples: {gpu_path}")
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(
        [scenario, pct, repeat, *r[1:9], r[9], r[14], r[15],
         f"{sum(x for x, _ in samples) / len(samples):.6f}",
         f"{sum(x for _, x in samples) / len(samples):.6f}",
         f"{max(x for _, x in samples):.6f}"])
print(f"[PASS] {scenario:9s} pct={pct:>3s} r={repeat} "
      f"throughput={float(r[2]):8.1f} MiB/s ratio={float(r[5])*100:6.2f}% "
      f"host_cpu={float(r[8]):.3f}")
PY
}

read -r -a pct_values <<< "$PCTS"
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % ${#pct_values[@]} ))
    for pi in "${!pct_values[@]}"; do
        pct="${pct_values[$(( (pi + shift) % ${#pct_values[@]} ))]}"
        if (( repeat % 2 == 1 )); then scenarios=(cpu gpu_batch); else scenarios=(gpu_batch cpu); fi
        for scenario in "${scenarios[@]}"; do run_one "$scenario" "$pct" "$repeat"; done
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" \
    "$RESULT_DIR/conclusions.txt" <<'PY'
import csv
import math
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
metrics = ["mib_s", "ratio", "cpu_cores", "maxrss_kib", "gpu_util_pct", "gpu_power_w"]
groups = {}
for r in rows:
    groups.setdefault((r["scenario"], int(r["requested_compressible_pct"])), []).append(r)
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scenario", "requested_compressible_pct", "n"] +
               [x for m in metrics for x in (f"{m}_mean", f"{m}_ci95")])
    for key in sorted(groups, key=lambda x: (x[1], x[0])):
        items = groups[key]
        out = [*key, len(items)]
        for metric in metrics:
            values = [float(r[metric]) for r in items]
            mean = statistics.mean(values)
            ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values)) if len(values) > 1 else 0
            out += [f"{mean:.6f}", f"{ci:.6f}"]
        w.writerow(out)
with open(sys.argv[3], "w") as f:
    for pct in sorted({key[1] for key in groups}):
        c, g = groups[("cpu", pct)], groups[("gpu_batch", pct)]
        avg = lambda rs, field: statistics.mean(float(r[field]) for r in rs)
        f.write(
            f"pct={pct} ratio_cpu={avg(c, 'ratio'):.6f} ratio_gpu={avg(g, 'ratio'):.6f} "
            f"cpu_mib_s={avg(c, 'mib_s'):.3f} gpu_mib_s={avg(g, 'mib_s'):.3f} "
            f"gpu_vs_cpu={avg(g, 'mib_s') / avg(c, 'mib_s'):.3f}x "
            f"cpu_host={avg(c, 'cpu_cores'):.3f} gpu_host={avg(g, 'cpu_cores'):.3f}\n")
PY

sha256sum "$PROJECT_DIR/tests/benchmark_lz4_compress.cpp" \
    "$PROJECT_DIR/tests/lz4_compress_sensitivity.sh" \
    "$PROJECT_DIR/src/gpu_lz4.cu" "$PROJECT_DIR/src/cpu_lz4.c" \
    > "$RESULT_DIR/SOURCE_MANIFEST.sha256"
echo "[OK] LZ4 compression sensitivity complete: $RESULT_DIR"
