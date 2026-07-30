#!/usr/bin/env bash
set -euo pipefail

# Regression for concurrent fio thread teardown on compressed files.
# Covers both compression formats and verifies timeout, fio errors and content.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/fio_compressed_threads_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-fio-threads-XXXXXX)"
SIZE="${GPUC_SIZE:-64M}"
RUNTIME="${GPUC_RUNTIME:-3}"
REPEATS="${GPUC_REPEATS:-5}"
BS_LIST="${GPUC_BS_LIST:-4k 16k 128k}"
THREAD_LIST="${GPUC_THREAD_LIST:-1 4}"
SAMPLE_TIMEOUT="${GPUC_SAMPLE_TIMEOUT:-$((RUNTIME + 30))}"

cleanup() {
    rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR/json" "$TEST_DIR/sglz" "$TEST_DIR/lz4"
make -C "$PROJECT_DIR" bin/libgpuhook.so bin/gpu_compress_daemon >/dev/null

PLAIN="$TEST_DIR/plain.bin"
SIZE_BYTES="$(numfmt --from=iec "$SIZE")"
python3 - "$PLAIN" "$SIZE_BYTES" <<'PY'
import sys

path, total = sys.argv[1], int(sys.argv[2])
page_size = 4096
with open(path, "wb", buffering=1024 * 1024) as f:
    for page in range((total + page_size - 1) // page_size):
        length = min(page_size, total - page * page_size)
        # Compressible but nonzero; each page differs to expose offset mistakes.
        value = ((page * 131 + 17) % 251) + 1
        f.write(bytes([value]) * length)
PY

PLAIN_SHA="$(sha256sum "$PLAIN" | awk '{print $1}')"
for algo in sglz lz4; do
    path="$TEST_DIR/$algo/data.bin"
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$PLAIN" "$path"
    if [ "$algo" = lz4 ]; then
        GPUC_ALGO=lz4 "$DAEMON" "$TEST_DIR/$algo" \
            > "$RESULT_DIR/daemon_${algo}.log" 2>&1
    else
        "$DAEMON" "$TEST_DIR/$algo" > "$RESULT_DIR/daemon_${algo}.log" 2>&1
    fi
done

state_of() {
    python3 - "$1" <<'PY'
import struct
import sys

with open(sys.argv[1], "rb") as f:
    header = f.read(56)
if len(header) < 56 or struct.unpack_from("<I", header, 0)[0] != 0x47505543:
    print("PLAIN")
else:
    print({0: "RAW", 1: "COMPRESSED", 2: "BUSY", 3: "INLINE"}.get(header[24], "UNKNOWN"))
PY
}

logical_sha() {
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
        dd if="$1" bs=1M status=none | sha256sum | awk '{print $1}'
}

for algo in sglz lz4; do
    path="$TEST_DIR/$algo/data.bin"
    [ "$(state_of "$path")" = COMPRESSED ] || {
        echo "[FAIL] $algo did not produce a COMPRESSED file" >&2
        sed -n '1,120p' "$RESULT_DIR/daemon_${algo}.log" >&2
        exit 1
    }
    [ "$(logical_sha "$path")" = "$PLAIN_SHA" ] || {
        echo "[FAIL] $algo setup checksum mismatch" >&2
        exit 1
    }
done

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "fio=$(fio --version)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)"
    echo "size=$SIZE"
    echo "runtime_s=$RUNTIME"
    echo "repeats=$REPEATS"
    echo "block_sizes=$BS_LIST"
    echo "fio_thread_jobs=$THREAD_LIST"
    echo "sample_timeout_s=$SAMPLE_TIMEOUT"
    echo "ioengine=sync"
    echo "cache=warm buffered I/O"
    echo "logical_sha256=$PLAIN_SHA"
} > "$RESULT_DIR/environment.txt"

echo "algo,bs,threads,repeat,bw_mib_s,iops,mean_lat_us,fio_runtime_ms,wall_ms,error,sha256" \
    > "$RESULT_DIR/runs.csv"

run_one() {
    local algo=$1 bs=$2 threads=$3 repeat=$4
    local path="$TEST_DIR/$algo/data.bin"
    local tag="${algo}_${bs}_t${threads}_r${repeat}"
    local json="$RESULT_DIR/json/$tag.json"
    local started ended status wall_ms sha

    # Warm data and CUDA before the timed section. This open/close is also a
    # lifecycle check, but the timed fio close is the original deadlock path.
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
        dd if="$path" of=/dev/null bs=1M status=none

    started="$(date +%s%N)"
    set +e
    timeout --signal=TERM --kill-after=10 "$SAMPLE_TIMEOUT" \
        env LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
        fio --name="$tag" --filename="$path" --size="$SIZE" --bs="$bs" \
            --rw=read --direct=0 --ioengine=sync --iodepth=1 \
            --thread=1 --numjobs="$threads" --runtime="$RUNTIME" --time_based \
            --invalidate=0 --group_reporting --readonly \
            --output-format=json --output="$json"
    status=$?
    set -e
    ended="$(date +%s%N)"
    wall_ms=$(((ended - started) / 1000000))

    if [ "$status" -ne 0 ]; then
        echo "[FAIL] $tag exited with status $status after ${wall_ms} ms" >&2
        [ -f "$json" ] && sed -n '1,80p' "$json" >&2
        exit 1
    fi

    sha="$(logical_sha "$path")"
    [ "$sha" = "$PLAIN_SHA" ] || {
        echo "[FAIL] $tag checksum mismatch" >&2
        exit 1
    }

    python3 - "$json" "$RESULT_DIR/runs.csv" "$algo" "$bs" "$threads" \
        "$repeat" "$wall_ms" "$sha" <<'PY'
import csv
import json
import sys

json_path, csv_path, algo, bs, threads, repeat, wall_ms, sha = sys.argv[1:]
with open(json_path) as f:
    data = json.load(f)
job = data["jobs"][0]
error = int(job.get("error", 0))
read = job["read"]
lat = read.get("lat_ns", {})
row = [
    algo, bs, threads, repeat,
    f'{float(read.get("bw", 0)) / 1024.0:.6f}',
    f'{float(read.get("iops", 0)):.6f}',
    f'{float(lat.get("mean", 0)) / 1000.0:.6f}',
    int(read.get("runtime", 0)),
    wall_ms,
    error,
    sha,
]
with open(csv_path, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(row)
if error:
    raise SystemExit(f"fio error={error}")
print(
    f"[PASS] {algo:4s} bs={bs:4s} threads={int(threads)} repeat={repeat} "
    f"wall={int(wall_ms)} ms bw={float(row[4]):.1f} MiB/s"
)
PY
}

for repeat in $(seq 1 "$REPEATS"); do
    for bs in $BS_LIST; do
        for threads in $THREAD_LIST; do
            for algo in sglz lz4; do
                run_one "$algo" "$bs" "$threads" "$repeat"
            done
        done
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv
import math
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
groups = {}
for row in rows:
    groups.setdefault((row["algo"], row["bs"], row["threads"]), []).append(row)
with open(sys.argv[2], "w", newline="") as f:
    out = csv.writer(f, lineterminator="\n")
    out.writerow([
        "algo", "bs", "threads", "n", "mean_mib_s", "ci95_mib_s",
        "mean_wall_ms", "max_wall_ms", "errors",
    ])
    for key, items in sorted(groups.items()):
        bw = [float(item["bw_mib_s"]) for item in items]
        wall = [int(item["wall_ms"]) for item in items]
        ci = 1.96 * statistics.stdev(bw) / math.sqrt(len(bw)) if len(bw) > 1 else 0.0
        out.writerow([
            *key, len(items), f"{statistics.mean(bw):.6f}", f"{ci:.6f}",
            f"{statistics.mean(wall):.3f}", max(wall),
            sum(int(item["error"]) for item in items),
        ])
PY

echo "[OK] fio compressed-thread regression passed: $RESULT_DIR"
