#!/usr/bin/env bash
set -euo pipefail

# CPU/GPU LZ4 decompression resource sensitivity across target throughput and
# input compressibility. The business workers and decompressor intentionally
# share core 0 by default to reproduce the service-contention question.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/offload_sensitivity_${RUN_ID}}"
BENCH="$PROJECT_DIR/bin/test_cpu_offload"
DURATION="${GPUC_RUNTIME:-5}"
REPEATS="${GPUC_REPEATS:-5}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-128}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-128}"
WORKERS="${GPUC_BUSINESS_WORKERS:-4}"
DECOMP_CPU="${GPUC_DECOMP_CPU:-0}"
TARGETS="${GPUC_TARGETS_MIB_S:-1024 2048 4096}"
PCTS="${GPUC_COMPRESSIBLE_PCTS:-0 50 100}"
export GPUC_WORKER_CPU="${GPUC_WORKER_CPU:-$DECOMP_CPU}"

for value in "$DURATION" "$REPEATS" "$WORKSET_MIB" "$BATCH_BLOCKS" "$WORKERS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: runtime, repeats, workset, batch and workers must be positive integers" >&2
        exit 2
    }
done
for value in $TARGETS; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: invalid target: $value" >&2; exit 2; }
done
for value in $PCTS; do
    [[ "$value" =~ ^[0-9]+$ ]] && (( value <= 100 )) || {
        echo "ERROR: invalid compressible percentage: $value" >&2; exit 2
    }
done

make -C "$PROJECT_DIR" bin/test_cpu_offload >/dev/null
mkdir -p "$RESULT_DIR/raw"

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader | head -1)"
    echo "runtime_s=$DURATION"
    echo "repeats=$REPEATS"
    echo "workset_mib=$WORKSET_MIB"
    echo "batch_blocks=$BATCH_BLOCKS"
    echo "business_workers=$WORKERS"
    echo "decomp_cpu=$DECOMP_CPU"
    echo "gpu_worker_cpu=$GPUC_WORKER_CPU"
    echo "targets_mib_s=$TARGETS"
    echo "requested_compressible_pcts=$PCTS"
    echo "data=deterministic 4 KiB pages; requested percentage uses repeated-byte pages and the remainder deterministic pseudo-random pages"
    echo "affinity=business workers pinned to cores 0..N-1; submit/decompressor pinned to decomp_cpu"
} > "$RESULT_DIR/environment.txt"

echo "scenario,target_mib_s,requested_compressible_pct,actual_stored_ratio,repeat,elapsed_s,business_ops_s,decomp_mib_s,target_attainment_pct,user_s,sys_s,process_cpu_cores,submit_cpu_s,worker_cpu_s,maxrss_kib,queue_ms,pack_ms,h2d_ms,kernel_ms,d2h_ms,unpack_ms,total_ms,gpu_util_pct,gpu_power_w" \
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
    local scenario=$1 target=$2 pct=$3 repeat=$4
    local tag="${scenario}_t${target}_p${pct}_r${repeat}"
    local app="$RESULT_DIR/raw/${tag}_app.csv"
    local info="$RESULT_DIR/raw/${tag}_data.csv"
    local gpu="$RESULT_DIR/raw/${tag}_gpu.csv"

    nvidia-smi --query-gpu=utilization.gpu,power.draw \
        --format=csv,noheader,nounits --loop-ms=200 > "$gpu" 2>/dev/null &
    sampler_pid=$!
    GPUC_WORKSET_MIB="$WORKSET_MIB" GPUC_BATCH_BLOCKS="$BATCH_BLOCKS" \
        GPUC_COMPRESSIBLE_PCT="$pct" GPUC_DATA_INFO_FILE="$info" \
        "$BENCH" "$scenario" "$DURATION" "$WORKERS" "$DECOMP_CPU" "$target" > "$app"
    cleanup_sampler

    python3 - "$scenario" "$target" "$pct" "$repeat" "$app" "$info" \
        "$gpu" "$RESULT_DIR/runs.csv" <<'PY'
import csv
import sys

scenario, target, pct, repeat, app_path, info_path, gpu_path, output = sys.argv[1:]
names = ["scenario", "elapsed", "workers", "business", "decomp", "user", "system",
         "submit_user", "submit_system", "maxrss", "minflt", "majflt", "nvcsw",
         "nivcsw", "calls", "queue_ms", "pack_ms", "h2d_ms", "kernel_ms", "d2h_ms",
         "unpack_ms", "total_ms", "worker_user", "worker_system", "pinned"]
rows = [r for r in csv.reader(open(app_path)) if len(r) == len(names)]
if not rows:
    raise SystemExit(f"missing benchmark row: {app_path}")
r = dict(zip(names, rows[-1]))
info = next(csv.DictReader(open(info_path)))
samples = []
for row in csv.reader(open(gpu_path, errors="replace")):
    try: samples.append((float(row[0]), float(row[1])))
    except (ValueError, IndexError): pass
if not samples:
    raise SystemExit(f"missing GPU samples: {gpu_path}")
elapsed = float(r["elapsed"])
decomp = float(r["decomp"])
target_value = float(target)
attainment = decomp / target_value * 100 if target_value else 0
user = float(r["user"])
system = float(r["system"])
row = [scenario, target, pct, info["stored_ratio"], repeat, r["elapsed"],
       r["business"], r["decomp"], f"{attainment:.6f}", r["user"], r["system"],
       f"{(user + system) / elapsed:.6f}",
       f"{float(r['submit_user']) + float(r['submit_system']):.6f}",
       f"{float(r['worker_user']) + float(r['worker_system']):.6f}", r["maxrss"],
       r["queue_ms"], r["pack_ms"], r["h2d_ms"], r["kernel_ms"], r["d2h_ms"],
       r["unpack_ms"], r["total_ms"],
       f"{sum(x for x, _ in samples) / len(samples):.6f}",
       f"{sum(x for _, x in samples) / len(samples):.6f}"]
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(row)
print(f"[PASS] {scenario:3s} target={target:>4s} pct={pct:>3s} r={repeat} "
      f"actual_ratio={float(info['stored_ratio'])*100:6.2f}% "
      f"decomp={decomp:8.1f} MiB/s business={float(r['business']):.0f} "
      f"cpu={(user+system)/elapsed:.3f}")
PY
}

# Baseline is independent of target and data percentage; execute five rotated
# rounds once rather than multiplying identical baseline samples.
for repeat in $(seq 1 "$REPEATS"); do
    run_one baseline 0 100 "$repeat"
done

read -r -a target_values <<< "$TARGETS"
read -r -a pct_values <<< "$PCTS"
for repeat in $(seq 1 "$REPEATS"); do
    target_shift=$(( (repeat - 1) % ${#target_values[@]} ))
    pct_shift=$(( (repeat - 1) % ${#pct_values[@]} ))
    for ti in "${!target_values[@]}"; do
        target="${target_values[$(( (ti + target_shift) % ${#target_values[@]} ))]}"
        for pi in "${!pct_values[@]}"; do
            pct="${pct_values[$(( (pi + pct_shift) % ${#pct_values[@]} ))]}"
            if (( repeat % 2 == 1 )); then scenarios=(cpu gpu); else scenarios=(gpu cpu); fi
            for scenario in "${scenarios[@]}"; do
                run_one "$scenario" "$target" "$pct" "$repeat"
            done
        done
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" \
    "$RESULT_DIR/conclusions.txt" <<'PY'
import csv
import math
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
metrics = ["actual_stored_ratio", "business_ops_s", "decomp_mib_s",
           "target_attainment_pct", "process_cpu_cores", "submit_cpu_s",
           "worker_cpu_s", "maxrss_kib", "gpu_util_pct", "gpu_power_w"]
baseline = [r for r in rows if r["scenario"] == "baseline"]
baseline_mean = statistics.mean(float(r["business_ops_s"]) for r in baseline)
groups = {}
for r in rows:
    key = (r["scenario"], int(r["target_mib_s"]), int(r["requested_compressible_pct"]))
    groups.setdefault(key, []).append(r)
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scenario", "target_mib_s", "requested_compressible_pct", "n",
                "business_vs_baseline_pct"] +
               [x for m in metrics for x in (f"{m}_mean", f"{m}_ci95")])
    for key in sorted(groups, key=lambda x: (x[1], x[2], x[0])):
        items = groups[key]
        business = statistics.mean(float(r["business_ops_s"]) for r in items)
        out = [*key, len(items), f"{business / baseline_mean * 100:.6f}"]
        for metric in metrics:
            values = [float(r[metric]) for r in items]
            mean = statistics.mean(values)
            ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values)) if len(values) > 1 else 0
            out += [f"{mean:.6f}", f"{ci:.6f}"]
        w.writerow(out)
with open(sys.argv[3], "w") as f:
    f.write(f"Baseline business throughput: {baseline_mean:.3f} ops/s\n")
    for target in sorted({k[1] for k in groups if k[0] != "baseline"}):
        for pct in sorted({k[2] for k in groups if k[0] != "baseline"}):
            c = groups[("cpu", target, pct)]
            g = groups[("gpu", target, pct)]
            avg = lambda rs, field: statistics.mean(float(r[field]) for r in rs)
            decomp_host = lambda rs: statistics.mean(
                (float(r["submit_cpu_s"]) + float(r["worker_cpu_s"])) /
                float(r["elapsed_s"]) for r in rs)
            f.write(
                f"target={target} pct={pct} actual_ratio={avg(c, 'actual_stored_ratio'):.6f} "
                f"cpu_business={avg(c, 'business_ops_s') / baseline_mean * 100:.2f}% "
                f"gpu_business={avg(g, 'business_ops_s') / baseline_mean * 100:.2f}% "
                f"cpu_decomp_host={decomp_host(c):.3f} "
                f"gpu_decomp_host={decomp_host(g):.3f} "
                f"cpu_attain={avg(c, 'target_attainment_pct'):.2f}% "
                f"gpu_attain={avg(g, 'target_attainment_pct'):.2f}%\n")
PY

sha256sum "$PROJECT_DIR/tests/test_cpu_offload.cpp" \
    "$PROJECT_DIR/tests/offload_sensitivity.sh" \
    "$PROJECT_DIR/src/gpu_lz4.cu" "$PROJECT_DIR/src/cpu_lz4.c" \
    > "$RESULT_DIR/SOURCE_MANIFEST.sha256"
echo "[OK] offload sensitivity complete: $RESULT_DIR"
