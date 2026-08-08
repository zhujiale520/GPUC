#!/usr/bin/env bash
set -euo pipefail

# Safe, disposable Btrfs zstd:3 vs ext4 baseline vs ext4+GPUC LZ4 comparison.
# This script only formats a loop device whose backing file it created itself.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/btrfs_zstd_${RUN_ID}}"
SIZE_MIB="${GPUC_SIZE_MIB:-256}"
RUNTIME="${GPUC_RUNTIME:-5}"
REPEATS="${GPUC_REPEATS:-5}"
DATA_MODE="${GPUC_DATA_MODE:-synthetic}"
CACHE_MODE="${GPUC_CACHE_MODE:-warm}"
PHYSICAL_GPU="${GPUC_PHYSICAL_GPU:-0}"
REAL_SOURCES="${GPUC_REAL_SOURCES:-/var/lib/dpkg/status /usr/bin/bash}"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
COMPSIZE="${GPUC_COMPSIZE:-}"
if [[ -z "$COMPSIZE" ]]; then
    COMPSIZE="$(command -v compsize || true)"
fi
if [[ -z "$COMPSIZE" ]]; then
    COMPSIZE="$PROJECT_DIR/third_party/manual/btrfs-compsize-root/usr/sbin/compsize"
fi
TEST_DIR="$(mktemp -d /tmp/gpuc-btrfs-XXXXXX)"
IMAGE="$TEST_DIR/btrfs.img"
MOUNT_DIR="$TEST_DIR/mnt"
LOOP_DEV=""

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Btrfs loop experiment requires root." >&2
    echo "Run: sudo env GPUC_RESULT_DIR=\"$PROJECT_DIR/results/local/btrfs_zstd\" bash tests/btrfs_compare.sh" >&2
    exit 2
fi
[[ "$SIZE_MIB" =~ ^[1-9][0-9]*$ && "$RUNTIME" =~ ^[1-9][0-9]*$ &&
   "$REPEATS" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: GPUC_SIZE_MIB, GPUC_RUNTIME and GPUC_REPEATS must be positive integers." >&2
    exit 2
}
[[ "$PHYSICAL_GPU" =~ ^[0-9]+$ ]] || {
    echo "ERROR: GPUC_PHYSICAL_GPU must be a non-negative integer." >&2
    exit 2
}
[[ "$DATA_MODE" == synthetic || "$DATA_MODE" == real ]] || {
    echo "ERROR: GPUC_DATA_MODE must be synthetic or real." >&2
    exit 2
}
[[ "$CACHE_MODE" == warm || "$CACHE_MODE" == cold ]] || {
    echo "ERROR: GPUC_CACHE_MODE must be warm or cold." >&2
    exit 2
}
if [[ "$CACHE_MODE" == cold ]]; then INVALIDATE=1; else INVALIDATE=0; fi
for command in mkfs.btrfs btrfs losetup mount umount fio; do
    command -v "$command" >/dev/null || { echo "ERROR: missing command: $command" >&2; exit 2; }
done
for path in "$HOOK" "$DAEMON"; do
    [[ -e "$path" ]] || { echo "ERROR: missing build artifact: $path" >&2; exit 2; }
done
[[ -x "$COMPSIZE" ]] || {
    echo "ERROR: missing compsize: $COMPSIZE" >&2
    echo "Install btrfs-compsize or extract it under third_party/manual." >&2
    exit 2
}

cleanup() {
    if mountpoint -q "$MOUNT_DIR" 2>/dev/null; then umount "$MOUNT_DIR" || true; fi
    if [[ "$LOOP_DEV" =~ ^/dev/loop[0-9]+$ ]]; then losetup -d "$LOOP_DEV" || true; fi
    rm -r -- "$TEST_DIR" 2>/dev/null || true
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" && -d "$RESULT_DIR" ]]; then
        chown -R "$SUDO_UID:$SUDO_GID" "$RESULT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR/json" "$TEST_DIR/ext4/plain" "$TEST_DIR/ext4/gpuc" "$MOUNT_DIR"
PLAIN="$TEST_DIR/ext4/plain/data.bin"
GPUC_FILE="$TEST_DIR/ext4/gpuc/data.bin"
BTRFS_FILE="$MOUNT_DIR/data.bin"

if [[ "$DATA_MODE" == synthetic ]]; then
python3 - "$PLAIN" "$SIZE_MIB" <<'PY'
import sys
path, size_mib = sys.argv[1], int(sys.argv[2])
total = size_mib * 1024 * 1024
with open(path, "wb", buffering=1024*1024) as f:
    for page in range((total + 4095)//4096):
        # Per-page content differs while retaining realistic compressibility.
        prefix = f"2026-07-30T12:00:{page%60:02d}Z storage request={page} status=ok ".encode()
        data = (prefix + bytes([(page * 131 + 17) % 251 + 1]) * 4096)[:4096]
        f.write(data[:min(4096, total - page*4096)])
PY
    echo "mode=synthetic; deterministic per-page storage request records" \
        > "$RESULT_DIR/corpus_sources.txt"
else
    read -r -a source_paths <<< "$REAL_SOURCES"
    (( ${#source_paths[@]} > 0 )) || { echo "ERROR: GPUC_REAL_SOURCES is empty." >&2; exit 2; }
    for source in "${source_paths[@]}"; do
        [[ -r "$source" && -f "$source" ]] || {
            echo "ERROR: real corpus source is not a readable regular file: $source" >&2
            exit 2
        }
    done
    sha256sum "${source_paths[@]}" > "$RESULT_DIR/corpus_sources.sha256"
    python3 - "$PLAIN" "$SIZE_MIB" "${source_paths[@]}" <<'PY'
import sys

output, size_mib, *sources = sys.argv[1:]
target = int(size_mib) * 1024 * 1024
parts = [open(path, "rb").read() for path in sources]
if not parts or not all(parts):
    raise SystemExit("real corpus contains an empty source")
written = 0
with open(output, "wb", buffering=1024 * 1024) as f:
    while written < target:
        for part in parts:
            chunk = part[:target - written]
            f.write(chunk)
            written += len(chunk)
            if written >= target:
                break
PY
    {
        echo "mode=real; source bytes repeated only to create a stable timed corpus"
        printf 'source=%s\n' "${source_paths[@]}"
    } > "$RESULT_DIR/corpus_sources.txt"
fi
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$PLAIN" "$GPUC_FILE"
GPUC_ALGO=lz4 "$DAEMON" "$TEST_DIR/ext4/gpuc" > "$RESULT_DIR/daemon.log" 2>&1

truncate -s 1G "$IMAGE"
LOOP_DEV="$(losetup --find --show "$IMAGE")"
[[ "$LOOP_DEV" =~ ^/dev/loop[0-9]+$ ]] || { echo "ERROR: unsafe loop path: $LOOP_DEV" >&2; exit 1; }
[[ "$(losetup -n -O BACK-FILE "$LOOP_DEV")" == "$IMAGE" ]] || {
    echo "ERROR: loop backing-file validation failed" >&2; exit 1;
}
mkfs.btrfs -f -L gpuc-disposable "$LOOP_DEV" > "$RESULT_DIR/mkfs.txt"
mount -o compress-force=zstd:3 "$LOOP_DEV" "$MOUNT_DIR"
cp "$PLAIN" "$BTRFS_FILE"
btrfs filesystem defragment -f -czstd "$BTRFS_FILE"
sync

plain_sha="$(sha256sum "$PLAIN" | awk '{print $1}')"
gpuc_sha="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 dd if="$GPUC_FILE" bs=1M status=none | sha256sum | awk '{print $1}')"
btrfs_sha="$(sha256sum "$BTRFS_FILE" | awk '{print $1}')"
[[ "$plain_sha" == "$gpuc_sha" && "$plain_sha" == "$btrfs_sha" ]] || {
    echo "ERROR: logical checksum mismatch" >&2; exit 1;
}
btrfs property get "$BTRFS_FILE" compression > "$RESULT_DIR/btrfs_property.txt"
btrfs filesystem du --raw "$BTRFS_FILE" > "$RESULT_DIR/btrfs_du.txt"
filefrag -v "$BTRFS_FILE" > "$RESULT_DIR/btrfs_filefrag.txt" 2>&1 || true
"$COMPSIZE" -b "$BTRFS_FILE" > "$RESULT_DIR/btrfs_compsize.txt"
BTRFS_DISK_BYTES="$(awk '$1=="TOTAL" {print $3}' "$RESULT_DIR/btrfs_compsize.txt")"
BTRFS_ZSTD_BYTES="$(awk '$1=="zstd" {print $3}' "$RESULT_DIR/btrfs_compsize.txt")"
[[ "$BTRFS_DISK_BYTES" =~ ^[0-9]+$ && "$BTRFS_ZSTD_BYTES" =~ ^[0-9]+$ ]] || {
    echo "ERROR: compsize did not report zstd extents" >&2
    cat "$RESULT_DIR/btrfs_compsize.txt" >&2
    exit 1
}
(( BTRFS_ZSTD_BYTES > 0 && BTRFS_DISK_BYTES < SIZE_MIB * 1024 * 1024 )) || {
    echo "ERROR: Btrfs zstd was not proven to reduce physical data" >&2
    cat "$RESULT_DIR/btrfs_compsize.txt" >&2
    exit 1
}

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "gpu=$(nvidia-smi -i "$PHYSICAL_GPU" --query-gpu=index,name,uuid,driver_version,compute_cap,memory.total --format=csv,noheader)"
    echo "physical_gpu=$PHYSICAL_GPU"
    echo "btrfs=$(mkfs.btrfs --version)"
    echo "fio=$(fio --version)"
    echo "source_mib=$SIZE_MIB"
    echo "source_sha256=$plain_sha"
    echo "runtime_s=$RUNTIME"
    echo "repeats=$REPEATS"
    echo "data_mode=$DATA_MODE"
    echo "real_sources=$REAL_SOURCES"
    echo "cache_mode=$CACHE_MODE"
    echo "fio_invalidate=$INVALIDATE"
    echo "cache_scope=file-level fio invalidate; no global drop_caches and no device-cache flush"
    echo "btrfs_mount_options=compress-force=zstd:3"
    echo "btrfs_data_disk_bytes=$BTRFS_DISK_BYTES"
    echo "btrfs_zstd_disk_bytes=$BTRFS_ZSTD_BYTES"
    echo "btrfs_space_source=compsize -b (extent-level physical data, excludes filesystem metadata)"
    echo "safety=formatted only validated loop device backed by $IMAGE"
} > "$RESULT_DIR/environment.txt"

echo "scenario,workload,repeat,bw_mib_s,iops,mean_lat_us,p99_lat_us,user_cpu_pct,sys_cpu_pct,error,logical_bytes,allocated_bytes,sha256" \
    > "$RESULT_DIR/runs.csv"

run_fio() {
    local scenario=$1 workload=$2 repeat=$3 path preload rw bs
    case "$scenario" in
        baseline) path="$PLAIN"; preload="" ;;
        gpuc_lz4) path="$GPUC_FILE"; preload="$HOOK" ;;
        btrfs_zstd) path="$BTRFS_FILE"; preload="" ;;
    esac
    case "$workload" in
        seq128k) rw=read; bs=128k ;;
        rand4k) rw=randread; bs=4k ;;
    esac
    local json="$RESULT_DIR/json/${scenario}_${workload}_r${repeat}.json"
    if [[ -n "$preload" ]]; then
        LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 fio --name="$scenario" \
            --filename="$path" --size="${SIZE_MIB}M" --rw="$rw" --bs="$bs" \
            --direct=0 --ioengine=sync --runtime="$RUNTIME" --time_based \
            --invalidate="$INVALIDATE" --numjobs=1 --thread=1 --readonly --output-format=json > "$json"
    else
        fio --name="$scenario" --filename="$path" --size="${SIZE_MIB}M" \
            --rw="$rw" --bs="$bs" --direct=0 --ioengine=sync --runtime="$RUNTIME" \
            --time_based --invalidate="$INVALIDATE" --numjobs=1 --thread=1 --readonly \
            --output-format=json > "$json"
    fi
    local allocated logical sha
    if [[ "$scenario" == btrfs_zstd ]]; then
        allocated="$BTRFS_DISK_BYTES"
    else
        allocated="$(du -B1 "$path" | awk '{print $1}')"
    fi
    logical="$((SIZE_MIB * 1024 * 1024))"
    sha="$plain_sha"
    python3 - "$json" "$RESULT_DIR/runs.csv" "$scenario" "$workload" "$repeat" \
        "$logical" "$allocated" "$sha" <<'PY'
import csv, json, sys
source, output, scenario, workload, repeat, logical, allocated, sha = sys.argv[1:]
d = json.load(open(source))
j = d["jobs"][0]
r = j["read"]
clat = r.get("clat_ns", r.get("lat_ns", {}))
p99 = clat.get("percentile", {}).get("99.000000", 0) / 1000
row = [scenario, workload, repeat, r["bw"]/1024, r["iops"],
       r["lat_ns"]["mean"]/1000, p99, j.get("usr_cpu", 0), j.get("sys_cpu", 0),
       j.get("error", 0), logical, allocated, sha]
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(row)
if int(row[9]): raise SystemExit(f"fio error={row[9]}")
print(f"[PASS] {scenario:11s} {workload:7s} r={repeat} bw={row[3]:.2f} MiB/s")
PY
}

for workload in seq128k rand4k; do
    scenarios=(baseline gpuc_lz4 btrfs_zstd)
    for repeat in $(seq 1 "$REPEATS"); do
        shift=$(( (repeat - 1) % 3 ))
        for index in 0 1 2; do
            run_fio "${scenarios[$(( (index + shift) % 3 ))]}" "$workload" "$repeat"
        done
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv, math, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
metrics = ["bw_mib_s", "iops", "mean_lat_us", "p99_lat_us",
           "user_cpu_pct", "sys_cpu_pct", "allocated_bytes"]
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scenario", "workload", "n"] +
               [x for m in metrics for x in (f"{m}_mean", f"{m}_ci95")])
    for workload in ("seq128k", "rand4k"):
        for scenario in ("baseline", "gpuc_lz4", "btrfs_zstd"):
            items = [r for r in rows if r["scenario"] == scenario and r["workload"] == workload]
            out = [scenario, workload, len(items)]
            for metric in metrics:
                values = [float(r[metric]) for r in items]
                mean = statistics.mean(values)
                ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values)) if len(values)>1 else 0
                out += [f"{mean:.6f}", f"{ci:.6f}"]
            w.writerow(out)
PY
sha256sum "$PROJECT_DIR/tests/btrfs_compare.sh" \
    "$PROJECT_DIR/src/hook.c" "$PROJECT_DIR/src/gpu_lz4.cu" \
    > "$RESULT_DIR/SOURCE_MANIFEST.sha256"
echo "[OK] Btrfs zstd comparison complete: $RESULT_DIR"
