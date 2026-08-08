#!/usr/bin/env bash
set -euo pipefail

# End-to-end A/B for legacy fixed 32-block LZ4 read-ahead versus request-aware
# adaptive read-ahead. One immutable compressed file is shared by both modes.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/lz4_readahead_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-lz4-ra-XXXXXX)"
SIZE="${GPUC_SIZE:-256M}"
RUNTIME="${GPUC_RUNTIME:-3}"
REPEATS="${GPUC_REPEATS:-5}"
THREAD_LIST="${GPUC_THREAD_LIST:-1 4}"
WORKLOADS="${GPUC_WORKLOADS:-randread:4k randread:128k read:128k}"
PHYSICAL_GPU="${GPUC_PHYSICAL_GPU:-0}"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
trap 'rm -rf -- "$TEST_DIR"' EXIT

[[ "$PHYSICAL_GPU" =~ ^[0-9]+$ ]] || {
    echo "ERROR: GPUC_PHYSICAL_GPU must be a non-negative integer." >&2
    exit 2
}

mkdir -p "$RESULT_DIR/json" "$RESULT_DIR/time" "$TEST_DIR/lz4"
make -C "$PROJECT_DIR" bin/libgpuhook.so bin/gpu_compress_daemon >/dev/null

PLAIN="$TEST_DIR/plain.bin"
COMPRESSED="$TEST_DIR/lz4/data.bin"
SIZE_BYTES="$(numfmt --from=iec "$SIZE")"
python3 - "$PLAIN" "$SIZE_BYTES" <<'PY'
import sys
path, total = sys.argv[1], int(sys.argv[2])
with open(path, "wb", buffering=1024 * 1024) as f:
    for page in range((total + 4095) // 4096):
        length = min(4096, total - page * 4096)
        f.write(bytes([1 + (page * 37) % 251]) * length)
PY
PLAIN_SHA="$(sha256sum "$PLAIN" | awk '{print $1}')"
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$PLAIN" "$COMPRESSED"
GPUC_ALGO=lz4 "$DAEMON" "$TEST_DIR/lz4" > "$RESULT_DIR/daemon.log" 2>&1
LOGICAL_SHA="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    dd if="$COMPRESSED" bs=1M status=none | sha256sum | awk '{print $1}')"
[[ "$PLAIN_SHA" == "$LOGICAL_SHA" ]]

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "gpu=$(nvidia-smi -i "$PHYSICAL_GPU" \
        --query-gpu=index,name,uuid,driver_version,compute_cap,memory.total \
        --format=csv,noheader | head -1)"
    echo "fio=$(fio --version)"
    echo "size=$SIZE"
    echo "runtime_s=$RUNTIME"
    echo "repeats=$REPEATS"
    echo "threads=$THREAD_LIST"
    echo "workloads=$WORKLOADS"
    echo "cache=warm buffered; physical file pre-read before each sample"
    echo "legacy=GPUC_LZ4_ADAPTIVE_READAHEAD=0, fixed 32 blocks"
    echo "adaptive=random starts at requested blocks; sequential grows 1/8/16/32"
    echo "logical_sha256=$PLAIN_SHA"
} > "$RESULT_DIR/environment.txt"

echo "mode,rw,bs,threads,repeat,bw_mib_s,iops,mean_lat_us,p99_us,maxrss_kib,user_cpu_pct,sys_cpu_pct,error" \
    > "$RESULT_DIR/runs.csv"

run_one() {
    local mode=$1 rw=$2 bs=$3 threads=$4 repeat=$5
    local adaptive=1
    [[ "$mode" == legacy ]] && adaptive=0
    local tag="${mode}_${rw}_${bs}_t${threads}_r${repeat}"
    local json="$RESULT_DIR/json/$tag.json"
    local time_log="$RESULT_DIR/time/$tag.txt"

    # Warm the physical file and CUDA context outside the measured process.
    GPUC_LZ4_ADAPTIVE_READAHEAD="$adaptive" LD_PRELOAD="$HOOK" \
        GPUCOMPRESS_QUIET=1 dd if="$COMPRESSED" of=/dev/null bs=1M status=none

    /usr/bin/time -v -o "$time_log" \
        env GPUC_LZ4_ADAPTIVE_READAHEAD="$adaptive" LD_PRELOAD="$HOOK" \
        GPUCOMPRESS_QUIET=1 \
        fio --name="$tag" --filename="$COMPRESSED" --size="$SIZE" \
            --rw="$rw" --bs="$bs" --direct=0 --invalidate=0 \
            --ioengine=sync --iodepth=1 --thread=1 --numjobs="$threads" \
            --runtime="$RUNTIME" --time_based --group_reporting --readonly \
            --randrepeat=1 --norandommap=1 --percentile_list=99 \
            --output-format=json --output="$json"

    python3 - "$json" "$time_log" "$RESULT_DIR/runs.csv" "$mode" "$rw" \
        "$bs" "$threads" "$repeat" <<'PY'
import csv, json, re, sys
json_path, time_path, output, mode, rw, bs, threads, repeat = sys.argv[1:]
job = json.load(open(json_path))["jobs"][0]
read = job["read"]
lat = read.get("clat_ns") or read.get("lat_ns") or {}
p99 = float(lat.get("percentile", {}).get("99.000000", 0)) / 1000.0
text = open(time_path, errors="replace").read()
match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", text)
rss = int(match.group(1)) if match else 0
row = [
    mode, rw, bs, threads, repeat,
    f"{float(read.get('bw', 0)) / 1024.0:.6f}",
    f"{float(read.get('iops', 0)):.6f}",
    f"{float(lat.get('mean', 0)) / 1000.0:.6f}",
    f"{p99:.6f}", rss,
    f"{float(job.get('usr_cpu', 0)):.6f}",
    f"{float(job.get('sys_cpu', 0)):.6f}",
    int(job.get("error", 0)),
]
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(row)
if row[-1]:
    raise SystemExit(f"fio error={row[-1]}")
print(
    f"[PASS] {mode:8s} {rw:8s} bs={bs:4s} t={threads} r={repeat} "
    f"bw={float(row[5]):.1f} MiB/s p99={p99:.1f} us rss={rss} KiB"
)
PY
}

for repeat in $(seq 1 "$REPEATS"); do
    if (( repeat % 2 )); then modes=(legacy adaptive); else modes=(adaptive legacy); fi
    for workload in $WORKLOADS; do
        rw="${workload%%:*}"
        bs="${workload#*:}"
        for threads in $THREAD_LIST; do
            for mode in "${modes[@]}"; do
                run_one "$mode" "$rw" "$bs" "$threads" "$repeat"
            done
        done
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv, math, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
keys = ["mode", "rw", "bs", "threads"]
metrics = ["bw_mib_s", "iops", "mean_lat_us", "p99_us", "maxrss_kib",
           "user_cpu_pct", "sys_cpu_pct"]
groups = {}
for row in rows:
    groups.setdefault(tuple(row[k] for k in keys), []).append(row)
with open(sys.argv[2], "w", newline="") as f:
    writer = csv.writer(f, lineterminator="\n")
    header = keys + ["n"]
    for metric in metrics:
        header += [f"{metric}_mean", f"{metric}_ci95"]
    writer.writerow(header)
    for key, samples in sorted(groups.items()):
        output = [*key, len(samples)]
        for metric in metrics:
            values = [float(row[metric]) for row in samples]
            ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values))
            output += [f"{statistics.mean(values):.6f}", f"{ci:.6f}"]
        writer.writerow(output)
PY
echo "[OK] LZ4 adaptive read-ahead A/B complete: $RESULT_DIR"
