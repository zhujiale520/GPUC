#!/usr/bin/env bash
set -euo pipefail

# CPU liblz4 vs GPU nvCOMP LZ4 compression, using the same input, block size,
# batch size and process-level measurements. gpu_serial is the strict ablation
# of the old per-block synchronization path.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/lz4_compress_fair_${RUN_ID}}"
BENCH="$PROJECT_DIR/bin/benchmark_lz4_compress"
RUNTIME="${GPUC_RUNTIME:-5}"
REPEATS="${GPUC_REPEATS:-5}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-512}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-32}"
TARGET_MIB_S="${GPUC_TARGET_MIB_S:-1024}"
COMPRESSIBLE_PCT="${GPUC_COMPRESSIBLE_PCT:-100}"

[[ -x "$BENCH" ]] || make -C "$PROJECT_DIR" bin/benchmark_lz4_compress
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
    echo "fair_target_mib_s=$TARGET_MIB_S"
    echo "requested_compressible_pct=$COMPRESSIBLE_PCT"
    echo "gpu_serial=ablation of per-block launch and synchronization; runs unthrottled"
    echo "gpu_energy_scope=board power sampled by nvidia-smi, including idle board power"
} > "$RESULT_DIR/environment.txt"

echo "scenario,repeat,elapsed_s,mib_s,logical_bytes,stored_bytes,ratio,user_s,sys_s,cpu_cores,maxrss_kib,minflt,majflt,nvcsw,nivcsw,batches,checksum,gpu_util_avg_pct,gpu_power_avg_w,gpu_power_max_w,gpu_board_j" \
    > "$RESULT_DIR/runs.csv"

run_one() {
    local scenario=$1 repeat=$2 backend target serial
    case "$scenario" in
        cpu) backend=cpu; target="$TARGET_MIB_S"; serial=0 ;;
        gpu_batch) backend=gpu; target="$TARGET_MIB_S"; serial=0 ;;
        gpu_serial) backend=gpu; target=0; serial=1 ;;
        *) echo "unknown scenario: $scenario" >&2; exit 2 ;;
    esac
    local tag="${scenario}_r${repeat}"
    local app="$RESULT_DIR/raw/${tag}_app.csv"
    local gpu="$RESULT_DIR/raw/${tag}_gpu.csv"

    nvidia-smi --query-gpu=timestamp,utilization.gpu,power.draw,memory.used \
        --format=csv,noheader,nounits --loop-ms=200 > "$gpu" 2>/dev/null &
    local sampler_pid=$!
    set +e
    GPUC_TARGET_MIB_S="$target" GPUC_LZ4_SERIAL_COMPRESS="$serial" \
        "$BENCH" "$backend" "$RUNTIME" "$WORKSET_MIB" "$BATCH_BLOCKS" > "$app"
    local rc=$?
    set -e
    kill "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
    [[ "$rc" -eq 0 ]] || { echo "[FAIL] $scenario repeat=$repeat" >&2; exit "$rc"; }

    python3 - "$scenario" "$repeat" "$app" "$gpu" "$RESULT_DIR/runs.csv" <<'PY'
import csv
import sys

scenario, repeat, app_path, gpu_path, output = sys.argv[1:]
rows = [r for r in csv.reader(open(app_path)) if len(r) == 16]
if not rows:
    raise SystemExit(f"missing benchmark row: {app_path}")
r = rows[-1]
samples = []
for row in csv.reader(open(gpu_path, errors="replace")):
    try:
        samples.append((float(row[1]), float(row[2])))
    except (ValueError, IndexError):
        pass
if not samples:
    raise SystemExit(f"missing nvidia-smi samples: {gpu_path}")
util = sum(x[0] for x in samples) / len(samples)
power = sum(x[1] for x in samples) / len(samples)
power_max = max(x[1] for x in samples)
elapsed = float(r[1])
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(
        [scenario, repeat, *r[1:], f"{util:.6f}", f"{power:.6f}",
         f"{power_max:.6f}", f"{power * elapsed:.6f}"]
    )
print(f"[PASS] {scenario:10s} repeat={repeat} throughput={float(r[2]):.2f} MiB/s "
      f"host_cpu={float(r[8]):.3f} cores gpu={util:.1f}% power={power:.1f} W")
PY
}

scenarios=(cpu gpu_batch gpu_serial)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 3 ))
    for index in 0 1 2; do
        run_one "${scenarios[$(( (index + shift) % 3 ))]}" "$repeat"
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" "$RESULT_DIR/conclusions.txt" <<'PY'
import csv
import math
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
metrics = ["mib_s", "ratio", "user_s", "sys_s", "cpu_cores", "maxrss_kib",
           "gpu_util_avg_pct", "gpu_power_avg_w", "gpu_board_j"]
groups = {name: [r for r in rows if r["scenario"] == name]
          for name in ("cpu", "gpu_batch", "gpu_serial")}
summary = {}
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scenario", "n"] + [x for m in metrics for x in (f"{m}_mean", f"{m}_ci95")])
    for name, items in groups.items():
        out = [name, len(items)]
        summary[name] = {}
        for metric in metrics:
            values = [float(r[metric]) for r in items]
            mean = statistics.mean(values)
            ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values)) if len(values) > 1 else 0
            summary[name][metric] = mean
            out += [f"{mean:.6f}", f"{ci:.6f}"]
        w.writerow(out)
c, g, old = summary["cpu"], summary["gpu_batch"], summary["gpu_serial"]
with open(sys.argv[3], "w") as f:
    f.write(f"At the common target, CPU host cost: {c['cpu_cores']:.3f} cores\n")
    f.write(f"At the common target, GPU host cost: {g['cpu_cores']:.3f} cores\n")
    f.write(f"GPU host CPU reduction: {(1-g['cpu_cores']/c['cpu_cores'])*100:.1f}%\n")
    f.write(f"GPU batch vs serial throughput speedup: {g['mib_s']/old['mib_s']:.2f}x "
            "(batch is target-limited)\n")
    f.write(f"Compression ratio equality delta: {abs(c['ratio']-g['ratio']):.9f}\n")
    f.write("Board energy includes idle GPU board power; CPU package/whole-system energy is not measured.\n")
PY

echo "[OK] LZ4 compression comparison complete: $RESULT_DIR"
