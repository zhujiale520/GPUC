#!/usr/bin/env bash
set -euo pipefail

# End-to-end read-only SQLite point/range queries directly against one GPUC
# LZ4 object. This is intentionally separate from sqlite_offload_business.sh,
# where SQLite only competes with an independent decompression workload.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/sqlite_direct_read_${RUN_ID}}"
RUNTIME="${GPUC_RUNTIME:-5}"
REPEATS="${GPUC_REPEATS:-5}"
ROWS="${GPUC_SQLITE_ROWS:-100000}"
SPAN="${GPUC_SQLITE_SPAN:-256}"
WORKERS="${GPUC_SQLITE_WORKERS:-1}"
PAYLOAD_MODE="${GPUC_SQLITE_PAYLOAD_MODE:-mixed}"
if [[ "${GPUC_LZ4_ADAPTIVE_READAHEAD:-1}" == 0 ]]; then
    READAHEAD_MODE="fixed32"
else
    READAHEAD_MODE="adaptive"
fi
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
WORK_DIR="$(mktemp -d /tmp/gpuc-sqlite-direct-XXXXXX)"
PLAIN="$WORK_DIR/source.db"
COMP_DIR="$WORK_DIR/compressed"
COMPRESSED="$COMP_DIR/database.gpuc"

for value in "$RUNTIME" "$REPEATS" "$ROWS" "$SPAN" "$WORKERS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: runtime, repeats, rows, span and workers must be positive integers." >&2
        exit 2
    }
done
(( SPAN < ROWS )) || { echo "ERROR: GPUC_SQLITE_SPAN must be less than rows." >&2; exit 2; }
[[ "$PAYLOAD_MODE" == constant || "$PAYLOAD_MODE" == mixed ]] || {
    echo "ERROR: GPUC_SQLITE_PAYLOAD_MODE must be constant or mixed." >&2
    exit 2
}
cleanup() { rm -r -- "$WORK_DIR" 2>/dev/null || true; }
trap cleanup EXIT

make -C "$PROJECT_DIR" bin/libgpuhook.so bin/gpu_compress_daemon >/dev/null
mkdir -p "$RESULT_DIR/raw" "$COMP_DIR"
python3 "$PROJECT_DIR/tests/sqlite_business.py" \
    --db "$PLAIN" --rows "$ROWS" --span "$SPAN" --workers 1 --duration 0.1 \
    --payload-mode "$PAYLOAD_MODE" --prepare >/dev/null
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 GPUC_ALGO=lz4 cp "$PLAIN" "$COMPRESSED"
GPUC_ALGO=lz4 "$GPU_DAEMON" "$COMP_DIR" > "$RESULT_DIR/daemon.log" 2>&1

algorithm_id="$(python3 - "$COMPRESSED" <<'PY'
import struct
import sys
with open(sys.argv[1], "rb") as f:
    header = f.read(56)
if len(header) < 56 or struct.unpack_from("<I", header, 0)[0] != 0x47505543:
    raise SystemExit("missing GPUC header")
print(header[25])
PY
)"
[[ "$algorithm_id" == 2 ]] || {
    echo "ERROR: direct SQLite fixture is not LZ4 (algorithm_id=$algorithm_id)." >&2
    exit 1
}

plain_sha="$(sha256sum "$PLAIN" | awk '{print $1}')"
logical_sha="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 GPUCOMPRESS_BACKEND=cpu \
    dd if="$COMPRESSED" bs=1M status=none | sha256sum | awk '{print $1}')"
[[ "$plain_sha" == "$logical_sha" ]] || { echo "ERROR: compressed SQLite SHA mismatch." >&2; exit 1; }
logical_bytes="$(stat -c %s "$PLAIN")"
physical_bytes="$(stat -c %s "$COMPRESSED")"
allocated_bytes="$(du -B1 "$COMPRESSED" | awk '{print $1}')"

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader | head -1)"
    echo "python=$(python3 --version 2>&1)"
    echo "sqlite=$(python3 -c 'import sqlite3; print(sqlite3.sqlite_version)')"
    echo "runtime_s=$RUNTIME"
    echo "repeats=$REPEATS"
    echo "rows=$ROWS"
    echo "range_span=$SPAN"
    echo "workers=$WORKERS"
    echo "payload_mode=$PAYLOAD_MODE"
    echo "lz4_readahead_mode=$READAHEAD_MODE"
    echo "compression_algorithm=lz4"
    echo "compression_algorithm_id=$algorithm_id"
    echo "small_read_cpu_blocks=${GPUC_LZ4_SMALL_READ_CPU_BLOCKS:-1}"
    echo "logical_bytes=$logical_bytes"
    echo "physical_bytes=$physical_bytes"
    echo "allocated_bytes=$allocated_bytes"
    echo "allocated_ratio=$(awk -v a="$allocated_bytes" -v l="$logical_bytes" 'BEGIN{printf "%.9f",a/l}')"
    echo "logical_sha256=$plain_sha"
    echo "workload=read-only indexed range aggregate directly against SQLite database; one untimed prewarm query per worker"
    echo "cache_scope=warm application/OS path; new process and decompression cache per repeat"
    echo "write_semantics=SQLite mode=ro; database object immutable during benchmark"
} > "$RESULT_DIR/environment.txt"

echo "scenario,repeat,elapsed_s,operations,qps,latency_mean_us,latency_p50_us,latency_p95_us,latency_p99_us,user_s,sys_s,cpu_cores,maxrss_kib,gpu_util_pct,gpu_power_w" \
    > "$RESULT_DIR/runs.csv"

sampler_pid=""
cleanup_sampler() {
    if [[ -n "$sampler_pid" ]]; then
        kill "$sampler_pid" 2>/dev/null || true
        wait "$sampler_pid" 2>/dev/null || true
        sampler_pid=""
    fi
}
trap 'cleanup_sampler; cleanup' EXIT

run_one() {
    local scenario=$1 repeat=$2 path backend
    local app="$RESULT_DIR/raw/${scenario}_r${repeat}_app.json"
    local usage="$RESULT_DIR/raw/${scenario}_r${repeat}_time.csv"
    local gpu="$RESULT_DIR/raw/${scenario}_r${repeat}_gpu.csv"
    if [[ "$scenario" == baseline ]]; then path="$PLAIN"; backend=""; else path="$COMPRESSED"; backend="$scenario"; fi

    nvidia-smi --query-gpu=utilization.gpu,power.draw \
        --format=csv,noheader,nounits --loop-ms=200 > "$gpu" 2>/dev/null &
    sampler_pid=$!
    if [[ -n "$backend" ]]; then
        /usr/bin/time -f '%U,%S,%M' -o "$usage" \
            env LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 GPUCOMPRESS_BACKEND="$backend" \
            python3 "$PROJECT_DIR/tests/sqlite_business.py" \
            --db "$path" --rows "$ROWS" --span "$SPAN" --workers "$WORKERS" \
            --duration "$RUNTIME" --payload-mode "$PAYLOAD_MODE" --prewarm \
            --sample-every 1 > "$app"
    else
        /usr/bin/time -f '%U,%S,%M' -o "$usage" \
            python3 "$PROJECT_DIR/tests/sqlite_business.py" \
            --db "$path" --rows "$ROWS" --span "$SPAN" --workers "$WORKERS" \
            --duration "$RUNTIME" --payload-mode "$PAYLOAD_MODE" --prewarm \
            --sample-every 1 > "$app"
    fi
    cleanup_sampler

    python3 - "$scenario" "$repeat" "$app" "$usage" "$gpu" "$RESULT_DIR/runs.csv" <<'PY'
import csv
import json
import sys

scenario, repeat, app_path, usage_path, gpu_path, output = sys.argv[1:]
d = json.load(open(app_path))
user, system, rss = map(float, open(usage_path).read().strip().split(","))
samples = []
for row in csv.reader(open(gpu_path, errors="replace")):
    try: samples.append((float(row[0]), float(row[1])))
    except (ValueError, IndexError): pass
if not samples: raise SystemExit(f"missing GPU samples: {gpu_path}")
elapsed = float(d["elapsed_sec"])
row = [scenario, repeat, elapsed, d["operations"], d["qps"],
       d["latency_mean_us"], d["latency_p50_us"], d["latency_p95_us"],
       d["latency_p99_us"], user, system, (user + system) / elapsed, rss,
       sum(x for x, _ in samples) / len(samples),
       sum(x for _, x in samples) / len(samples)]
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(row)
print(f"[PASS] {scenario:8s} r={repeat} qps={d['qps']:.1f} "
      f"p99={d['latency_p99_us']:.1f} us cpu={(user+system)/elapsed:.3f}")
PY
}

scenarios=(baseline cpu gpu)
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
metrics = ["qps", "latency_mean_us", "latency_p50_us", "latency_p95_us",
           "latency_p99_us", "cpu_cores", "maxrss_kib", "gpu_util_pct", "gpu_power_w"]
groups = {scenario: [r for r in rows if r["scenario"] == scenario]
          for scenario in ("baseline", "cpu", "gpu")}
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scenario", "n"] + [x for m in metrics for x in (f"{m}_mean", f"{m}_ci95")])
    for scenario, items in groups.items():
        out = [scenario, len(items)]
        for metric in metrics:
            values = [float(r[metric]) for r in items]
            mean = statistics.mean(values)
            ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values)) if len(values) > 1 else 0
            out += [f"{mean:.6f}", f"{ci:.6f}"]
        w.writerow(out)
avg = lambda scenario, metric: statistics.mean(float(r[metric]) for r in groups[scenario])
with open(sys.argv[3], "w") as f:
    for scenario in ("cpu", "gpu"):
        f.write(f"{scenario} qps={avg(scenario, 'qps'):.3f} "
                f"vs_baseline={(avg(scenario, 'qps') / avg('baseline', 'qps') - 1) * 100:+.2f}% "
                f"p99_us={avg(scenario, 'latency_p99_us'):.3f} "
                f"cpu_cores={avg(scenario, 'cpu_cores'):.3f}\n")
    f.write(f"gpu_vs_cpu_qps={(avg('gpu', 'qps') / avg('cpu', 'qps') - 1) * 100:+.2f}%\n")
PY

sha256sum "$PROJECT_DIR/tests/sqlite_business.py" \
    "$PROJECT_DIR/tests/sqlite_direct_read.sh" "$PROJECT_DIR/src/hook.c" \
    "$PROJECT_DIR/src/gpu_lz4.cu" "$PROJECT_DIR/src/cpu_lz4.c" \
    "$PROJECT_DIR/src/daemon.c" \
    > "$RESULT_DIR/SOURCE_MANIFEST.sha256"
echo "[OK] direct SQLite read complete: $RESULT_DIR"
