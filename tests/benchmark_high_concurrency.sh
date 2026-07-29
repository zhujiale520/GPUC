#!/usr/bin/env bash
set -euo pipefail

# Fair warm-cache high-concurrency benchmark.
# Baseline, Hook RAW and GPU Compressed are separate files with identical
# logical contents. Every run validates state and checksum before fio starts.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TESTDIR="$(mktemp -d /tmp/gpuc-concurrency-XXXXXX)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTDIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/high_concurrency_$RUN_ID}"

SIZE="${GPUC_SIZE:-512M}"
RUNTIME="${GPUC_RUNTIME:-15}"
REPEATS="${GPUC_REPEATS:-5}"
BS_LIST="${GPUC_BS_LIST:-128k 1M}"
JOBS_LIST="${GPUC_JOBS_LIST:-1 4 8 16 32}"
DIRECT="${GPUC_DIRECT:-0}"
FIO_THREADS="${GPUC_FIO_THREADS:-1}"
SAMPLE_TIMEOUT="${GPUC_SAMPLE_TIMEOUT:-$((RUNTIME + 60))}"

if [[ "$DIRECT" != "0" ]]; then
    echo "[ERROR] GPUC compact offsets are not O_DIRECT aligned. Use GPUC_DIRECT=0." >&2
    echo "        Cold-cache/O_DIRECT results must be reported separately; the Hook explicitly clears O_DIRECT for managed files." >&2
    exit 2
fi

cleanup() {
    rm -rf "$TESTDIR"
}
trap cleanup EXIT

mkdir -p "$TESTDIR/plain" "$TESTDIR/raw" "$TESTDIR/compressed" "$RESULTDIR/json"

for required in "$HOOK_SO" "$GPU_DAEMON"; do
    [ -f "$required" ] || { echo "[ERROR] Missing build artifact: $required" >&2; exit 1; }
done

PLAIN_FILE="$TESTDIR/plain/data.bin"
RAW_FILE="$TESTDIR/raw/data.bin"
COMP_FILE="$TESTDIR/compressed/data.bin"
SIZE_BYTES="$(numfmt --from=iec "$SIZE")"

generate_pattern_file() {
    python3 - "$PLAIN_FILE" "$SIZE_BYTES" <<'PY'
import sys

path = sys.argv[1]
total = int(sys.argv[2])
page_bytes = 4096
with open(path, "wb", buffering=1024 * 1024) as f:
    page = 0
    written = 0
    while written < total:
        # Non-zero and deterministic; each page differs but is compressible.
        value = ((page * 131 + 17) % 251) + 1
        n = min(page_bytes, total - written)
        f.write(bytes([value]) * n)
        written += n
        page += 1
PY
}

state_of() {
    python3 - "$1" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as f:
    h = f.read(56)
if len(h) < 56 or struct.unpack_from("<I", h, 0)[0] != 0x47505543:
    print("PLAIN")
else:
    print({0: "RAW", 1: "COMPRESSED", 2: "BUSY", 3: "INLINE"}.get(h[24], "UNKNOWN"))
PY
}

echo "[SETUP] Generating $SIZE deterministic input..."
generate_pattern_file
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 cp "$PLAIN_FILE" "$RAW_FILE"
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 cp "$PLAIN_FILE" "$COMP_FILE"

plain_sha="$(sha256sum "$PLAIN_FILE" | awk '{print $1}')"
raw_sha="$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if="$RAW_FILE" bs=1M status=none | sha256sum | awk '{print $1}')"
[ "$plain_sha" = "$raw_sha" ] || { echo "[FAIL] Hook RAW checksum mismatch"; exit 1; }
[ "$(state_of "$RAW_FILE")" = "RAW" ] || { echo "[FAIL] RAW file state invalid"; exit 1; }

"$GPU_DAEMON" "$TESTDIR/compressed" > "$RESULTDIR/daemon.log" 2>&1
[ "$(state_of "$COMP_FILE")" = "COMPRESSED" ] || {
    echo "[FAIL] Daemon did not produce a COMPRESSED file" >&2
    sed -n '1,120p' "$RESULTDIR/daemon.log" >&2
    exit 1
}
comp_sha="$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if="$COMP_FILE" bs=1M status=none | sha256sum | awk '{print $1}')"
[ "$plain_sha" = "$comp_sha" ] || { echo "[FAIL] GPU Compressed checksum mismatch"; exit 1; }

echo "[SETUP] Warming all three logical files and CUDA initialization..."
dd if="$PLAIN_FILE" of=/dev/null bs=1M status=none
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if="$RAW_FILE" of=/dev/null bs=1M status=none
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if="$COMP_FILE" of=/dev/null bs=1M status=none

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    echo "kernel=$(uname -srmo)"
    echo "fio=$(fio --version)"
    echo "size=$SIZE"
    echo "runtime=$RUNTIME"
    echo "repeats=$REPEATS"
    echo "direct=$DIRECT"
    echo "fio_threads=$FIO_THREADS"
    echo "sample_timeout_seconds=$SAMPLE_TIMEOUT"
    echo "cache_mode=warm (full logical pre-read before timed runs)"
    nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader 2>&1 || true
} > "$RESULTDIR/environment.txt"

echo "scenario,bs,jobs,direct,repeat,bw_mib_s,iops,mean_lat_us,error,state,sha256,apparent_bytes,allocated_bytes" \
    > "$RESULTDIR/runs.csv"

run_fio() {
    local scenario=$1
    local path=$2
    local preload=$3
    local bs=$4
    local jobs=$5
    local repeat=$6
    local json="$RESULTDIR/json/${scenario}_${bs}_j${jobs}_r${repeat}.json"
    local state sha apparent allocated

    state="$(state_of "$path")"
    apparent="$(stat -c %s "$path")"
    allocated="$(du -B1 "$path" | awk '{print $1}')"
    if [ -n "$preload" ]; then
        sha="$(LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 dd if="$path" bs=1M status=none | sha256sum | awk '{print $1}')"
    else
        sha="$(sha256sum "$path" | awk '{print $1}')"
    fi
    [ "$sha" = "$plain_sha" ] || { echo "[FAIL] $scenario checksum changed"; exit 1; }

    if [ -n "$preload" ]; then
        LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 timeout --signal=TERM --kill-after=10 \
            "$SAMPLE_TIMEOUT" fio \
            --name="$scenario" --filename="$path" --size="$SIZE" --bs="$bs" \
            --rw=read --direct="$DIRECT" --ioengine=sync --runtime="$RUNTIME" \
            --time_based --invalidate=0 --thread="$FIO_THREADS" --numjobs="$jobs" \
            --group_reporting --readonly \
            --output-format=json > "$json"
    else
        timeout --signal=TERM --kill-after=10 "$SAMPLE_TIMEOUT" fio \
            --name="$scenario" --filename="$path" --size="$SIZE" --bs="$bs" \
            --rw=read --direct="$DIRECT" --ioengine=sync --runtime="$RUNTIME" \
            --time_based --invalidate=0 --thread="$FIO_THREADS" --numjobs="$jobs" \
            --group_reporting --readonly \
            --output-format=json > "$json"
    fi

    python3 - "$json" "$RESULTDIR/runs.csv" "$scenario" "$bs" "$jobs" "$DIRECT" \
        "$repeat" "$state" "$sha" "$apparent" "$allocated" <<'PY'
import csv
import json
import sys

json_path, csv_path = sys.argv[1:3]
scenario, bs, jobs, direct, repeat, state, sha, apparent, allocated = sys.argv[3:]
with open(json_path) as f:
    data = json.load(f)
job = data["jobs"][0]
error = int(job.get("error", 0))
read = job["read"]
row = [
    scenario, bs, jobs, direct, repeat,
    f'{read["bw"] / 1024.0:.3f}',
    f'{read["iops"]:.3f}',
    f'{read["lat_ns"]["mean"] / 1000.0:.3f}',
    error, state, sha, apparent, allocated,
]
with open(csv_path, "a", newline="") as f:
    csv.writer(f).writerow(row)
if error:
    raise SystemExit(f"fio job error={error}: {scenario} bs={bs} jobs={jobs}")
print(f'{scenario:15s} bs={bs:5s} jobs={int(jobs):2d} repeat={repeat} '
      f'bw={float(row[5]):9.1f} MiB/s state={state}')
PY
}

for bs in $BS_LIST; do
    for jobs in $JOBS_LIST; do
        for repeat in $(seq 1 "$REPEATS"); do
            # Rotate order across repeats to reduce systematic thermal/cache bias.
            case $((repeat % 3)) in
                0)
                    order="gpu_compressed hook_raw baseline"
                    ;;
                1)
                    order="baseline gpu_compressed hook_raw"
                    ;;
                2)
                    order="hook_raw baseline gpu_compressed"
                    ;;
            esac
            for scenario in $order; do
                case "$scenario" in
                    baseline) run_fio baseline "$PLAIN_FILE" "" "$bs" "$jobs" "$repeat" ;;
                    hook_raw) run_fio hook_raw "$RAW_FILE" "$HOOK_SO" "$bs" "$jobs" "$repeat" ;;
                    gpu_compressed) run_fio gpu_compressed "$COMP_FILE" "$HOOK_SO" "$bs" "$jobs" "$repeat" ;;
                esac
            done
        done
    done
done

python3 - "$RESULTDIR/runs.csv" "$RESULTDIR/summary.csv" <<'PY'
import csv
import math
import statistics
import sys
from collections import defaultdict

rows = list(csv.DictReader(open(sys.argv[1])))
groups = defaultdict(list)
for row in rows:
    groups[(row["scenario"], row["bs"], row["jobs"], row["direct"])].append(float(row["bw_mib_s"]))

with open(sys.argv[2], "w", newline="") as f:
    out = csv.writer(f)
    out.writerow(["scenario", "bs", "jobs", "direct", "n", "mean_mib_s", "stddev_mib_s", "ci95_mib_s"])
    for key in sorted(groups):
        values = groups[key]
        mean = statistics.mean(values)
        stddev = statistics.stdev(values) if len(values) > 1 else 0.0
        ci95 = 1.96 * stddev / math.sqrt(len(values)) if len(values) > 1 else 0.0
        out.writerow([*key, len(values), f"{mean:.3f}", f"{stddev:.3f}", f"{ci95:.3f}"])
        print(f"{key}: mean={mean:.1f} MiB/s std={stddev:.1f} 95%CI=±{ci95:.1f}")
PY

echo "[OK] Raw data: $RESULTDIR/runs.csv"
echo "[OK] Summary:  $RESULTDIR/summary.csv"
