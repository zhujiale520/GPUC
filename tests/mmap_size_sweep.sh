#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
TEST_BIN="$PROJECT_DIR/bin/test_mmap_ondemand"
TESTDIR="$(mktemp -d /tmp/gpuc-mmap-XXXXXX)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULTDIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/mmap_$RUN_ID}"
SIZES="${GPUC_MMAP_SIZES:-64M 256M}"
REPEATS="${GPUC_REPEATS:-5}"
PHYSICAL_GPU="${GPUC_PHYSICAL_GPU:-0}"

[[ "$PHYSICAL_GPU" =~ ^[0-9]+$ ]] || {
    echo "ERROR: GPUC_PHYSICAL_GPU must be a non-negative integer." >&2
    exit 2
}

cleanup() {
    rm -rf "$TESTDIR"
}
trap cleanup EXIT

mkdir -p "$TESTDIR/plain" "$TESTDIR/raw" "$TESTDIR/compressed" "$RESULTDIR"

if [ ! -f "$HOOK_SO" ] || [ ! -f "$GPU_DAEMON" ]; then
    echo "[ERROR] Build GPU targets first: make all" >&2
    exit 1
fi

gcc -O3 -Wall -Wextra -pthread "$PROJECT_DIR/tests/test_mmap_ondemand.c" -o "$TEST_BIN"

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    echo "kernel=$(uname -srmo)"
    echo "sizes=$SIZES"
    echo "repeats=$REPEATS"
    echo "mmap_mode=${GPUC_MMAP_MODE:-auto}"
    echo "mmap_threads=${GPUC_MMAP_THREADS:-1}"
    echo "unprivileged_userfaultfd=$(cat /proc/sys/vm/unprivileged_userfaultfd 2>/dev/null || echo unavailable)"
    nvidia-smi -i "$PHYSICAL_GPU" \
        --query-gpu=index,name,uuid,driver_version,compute_cap,memory.total \
        --format=csv,noheader 2>&1 || true
} > "$RESULTDIR/environment.txt"
echo "size,scenario,repeat,mmap_ms,first_fault_us,scan_ms,pages,threads,checksum,mismatches,state" > "$RESULTDIR/results.csv"

generate_pattern_file() {
    local path=$1
    local size_bytes=$2
    python3 - "$path" "$size_bytes" <<'PY'
import sys

path = sys.argv[1]
total = int(sys.argv[2])
page_bytes = 4096
with open(path, "wb", buffering=1024 * 1024) as f:
    page = 0
    written = 0
    while written < total:
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
    header = f.read(56)
if len(header) < 56 or struct.unpack_from("<I", header, 0)[0] != 0x47505543:
    print("PLAIN")
else:
    print({0: "RAW", 1: "COMPRESSED", 2: "BUSY", 3: "INLINE"}.get(header[24], "UNKNOWN"))
PY
}

record_result() {
    local size_label=$1
    local scenario=$2
    local repeat=$3
    local state=$4
    local output=$5
    local mmap_ms first_fault_us scan_ms pages threads checksum mismatches
    mmap_ms="$(sed -n 's/.*mmap_ms=\([^ ]*\).*/\1/p' <<<"$output")"
    first_fault_us="$(sed -n 's/.*first_fault_us=\([^ ]*\).*/\1/p' <<<"$output")"
    scan_ms="$(sed -n 's/.*scan_ms=\([^ ]*\).*/\1/p' <<<"$output")"
    pages="$(sed -n 's/.*pages=\([^ ]*\).*/\1/p' <<<"$output")"
    threads="$(sed -n 's/.*threads=\([^ ]*\).*/\1/p' <<<"$output")"
    checksum="$(sed -n 's/.*checksum=\([^ ]*\).*/\1/p' <<<"$output")"
    mismatches="$(sed -n 's/.*mismatches=\([^ ]*\).*/\1/p' <<<"$output")"
    echo "$size_label,$scenario,$repeat,$mmap_ms,$first_fault_us,$scan_ms,$pages,$threads,$checksum,$mismatches,$state" >> "$RESULTDIR/results.csv"
    printf "%-8s %-12s r=%s mmap=%9s ms first=%9s us scan=%9s ms threads=%s state=%s\n" \
        "$size_label" "$scenario" "$repeat" "$mmap_ms" "$first_fault_us" "$scan_ms" "$threads" "$state"
}

for size_label in $SIZES; do
    size_bytes="$(numfmt --from=iec "$size_label")"
    plain="$TESTDIR/plain/data_$size_label.bin"
    raw="$TESTDIR/raw/data_$size_label.bin"
    compressed="$TESTDIR/compressed/data_$size_label.bin"

    echo "[SETUP] Generating deterministic non-zero page pattern: $size_label"
    generate_pattern_file "$plain" "$size_bytes"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 cp "$plain" "$raw"
    LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 cp "$plain" "$compressed"

    plain_sha="$(sha256sum "$plain" | awk '{print $1}')"
    raw_sha="$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if="$raw" bs=1M status=none | sha256sum | awk '{print $1}')"
    [ "$plain_sha" = "$raw_sha" ] || { echo "[FAIL] RAW checksum mismatch"; exit 1; }

    raw_state="$(state_of "$raw")"
    [ "$raw_state" = "RAW" ] || { echo "[FAIL] Expected RAW, got $raw_state"; exit 1; }

    "$GPU_DAEMON" "$TESTDIR/compressed" > "$RESULTDIR/daemon_$size_label.log" 2>&1
    comp_state="$(state_of "$compressed")"
    [ "$comp_state" = "COMPRESSED" ] || {
        echo "[FAIL] Expected COMPRESSED, got $comp_state" >&2
        exit 1
    }
    comp_sha="$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if="$compressed" bs=1M status=none | sha256sum | awk '{print $1}')"
    [ "$plain_sha" = "$comp_sha" ] || { echo "[FAIL] COMPRESSED checksum mismatch"; exit 1; }

    for repeat in $(seq 1 "$REPEATS"); do
        baseline_out="$("$TEST_BIN" "$plain")"
        record_result "$size_label" baseline "$repeat" PLAIN "$baseline_out"
        raw_out="$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 "$TEST_BIN" "$raw")"
        record_result "$size_label" hook_raw "$repeat" "$raw_state" "$raw_out"
        comp_out="$(LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 "$TEST_BIN" "$compressed")"
        record_result "$size_label" gpu_compressed "$repeat" "$comp_state" "$comp_out"
    done
done

python3 - "$RESULTDIR/results.csv" "$RESULTDIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1])))
metrics=["mmap_ms","first_fault_us","scan_ms"]
with open(sys.argv[2],"w",newline="") as f:
    w=csv.writer(f,lineterminator="\n")
    w.writerow(["size","scenario","threads","metric","n","mean","ci95"])
    for size in sorted({r["size"] for r in rows}):
        for scenario in ("baseline","hook_raw","gpu_compressed"):
            group=[r for r in rows if r["size"]==size and r["scenario"]==scenario]
            for metric in metrics:
                vals=[float(r[metric]) for r in group]
                ci=1.96*statistics.stdev(vals)/math.sqrt(len(vals)) if len(vals)>1 else 0
                w.writerow([size,scenario,group[0]["threads"],metric,len(vals),
                            statistics.mean(vals),ci])
PY

echo "[OK] mmap correctness and latency results: $RESULTDIR/results.csv"
