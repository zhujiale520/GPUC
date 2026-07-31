#!/usr/bin/env bash
set -euo pipefail

# Oracle Vdbench is license-gated and is not redistributed by this repository.
# After accepting Oracle's license, place 5.04.07 under third_party/manual or
# set VDBENCH_HOME. A project-private Java runtime is supported through
# GPUC_JAVA_HOME, so neither dependency needs a system-wide installation.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/vdbench_${RUN_ID}}"
VDBENCH_HOME="${VDBENCH_HOME:-$PROJECT_DIR/third_party/manual/vdbench50407}"
JAVA_HOME="${GPUC_JAVA_HOME:-$PROJECT_DIR/third_party/manual/java8}"
VDBENCH="$VDBENCH_HOME/vdbench"
JAVA="$JAVA_HOME/bin/java"
SIZE="${GPUC_SIZE:-256m}"
ELAPSED="${GPUC_RUNTIME:-10}"
WARMUP="${GPUC_WARMUP:-2}"
REPEATS="${GPUC_REPEATS:-5}"
THREADS="${GPUC_THREADS:-4}"
SAMPLE_TIMEOUT="${GPUC_SAMPLE_TIMEOUT:-$((ELAPSED + WARMUP + 60))}"
READ_WORKLOADS="${GPUC_READ_WORKLOADS:-seq_read random_read}"
READ_SCENARIOS="${GPUC_READ_SCENARIOS:-baseline hook_raw sglz lz4}"
RUN_MIXED="${GPUC_RUN_MIXED:-1}"
TEST_DIR="$(mktemp -d /tmp/gpuc-vdbench-XXXXXX)"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"

cleanup() {
    rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR/logs" "$TEST_DIR/raw" "$TEST_DIR/sglz" "$TEST_DIR/lz4"

{
    echo "official_download=https://www.oracle.com/downloads/server-storage/vdbench-downloads.html"
    echo "license=Oracle license acceptance and account login required"
    echo "VDBENCH_HOME=$VDBENCH_HOME"
    echo "GPUC_JAVA_HOME=$JAVA_HOME"
    echo "vdbench_zip_sha256=$(sha256sum "$PROJECT_DIR/third_party/manual/vdbench50407.zip" 2>/dev/null | awk '{print $1}' || echo unavailable)"
    echo "java=$([[ -x "$JAVA" ]] && "$JAVA" -version 2>&1 | head -1 || echo unavailable)"
    echo "vdbench=$([[ -x "$VDBENCH" ]] && echo "$VDBENCH" || echo unavailable)"
} > "$RESULT_DIR/capability.txt"

[[ -x "$VDBENCH" ]] || {
    echo "SKIP: accept the Oracle license, install Vdbench 5.04.07, and set VDBENCH_HOME." \
        | tee "$RESULT_DIR/SKIPPED.txt"
    exit 2
}
[[ -x "$JAVA" ]] || {
    echo "SKIP: install a Java runtime and set GPUC_JAVA_HOME." \
        | tee "$RESULT_DIR/SKIPPED.txt"
    exit 2
}
[[ -f "$HOOK" && -x "$DAEMON" ]] || {
    echo "ERROR: build bin/libgpuhook.so and bin/gpu_compress_daemon first." >&2
    exit 1
}

export PATH="$JAVA_HOME/bin:$PATH"

SIZE_BYTES="$(python3 - "$SIZE" <<'PY'
import re
import sys

match = re.fullmatch(r"([0-9]+)([kmgt]?)", sys.argv[1].strip(), re.I)
if not match:
    raise SystemExit("GPUC_SIZE must look like 256m, 1g, or a byte count")
value = int(match.group(1))
scale = {"": 1, "k": 1024, "m": 1024**2, "g": 1024**3, "t": 1024**4}
print(value * scale[match.group(2).lower()])
PY
)"

BASE="$TEST_DIR/baseline.bin"
RAW="$TEST_DIR/raw/data.bin"
SGLZ="$TEST_DIR/sglz/data.bin"
LZ4="$TEST_DIR/lz4/data.bin"

has_read_scenario() {
    local wanted=$1 scenario
    for scenario in $READ_SCENARIOS; do
        [[ "$scenario" = "$wanted" ]] && return 0
    done
    return 1
}

python3 - "$BASE" "$SIZE_BYTES" <<'PY'
import sys

path, total = sys.argv[1], int(sys.argv[2])
page_size = 4096
with open(path, "wb", buffering=1024 * 1024) as f:
    for page in range((total + page_size - 1) // page_size):
        length = min(page_size, total - page * page_size)
        value = ((page * 131 + 17) % 251) + 1
        f.write(bytes([value]) * length)
PY

if has_read_scenario hook_raw || [[ "$RUN_MIXED" = 1 ]]; then
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$BASE" "$RAW"
fi
if has_read_scenario sglz; then
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$BASE" "$SGLZ"
    GPUC_ALGO=sglz "$DAEMON" "$TEST_DIR/sglz" \
        > "$RESULT_DIR/daemon_sglz.log" 2>&1
fi
if has_read_scenario lz4; then
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$BASE" "$LZ4"
    GPUC_ALGO=lz4 "$DAEMON" "$TEST_DIR/lz4" \
        > "$RESULT_DIR/daemon_lz4.log" 2>&1
fi

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
    local path=$1 preload=$2
    if [[ -n "$preload" ]]; then
        LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
            dd if="$path" bs=1M status=none | sha256sum | awk '{print $1}'
    else
        sha256sum "$path" | awk '{print $1}'
    fi
}

BASE_SHA="$(logical_sha "$BASE" "")"
RAW_SHA="not-prepared"
SGLZ_SHA="not-prepared"
LZ4_SHA="not-prepared"
if has_read_scenario hook_raw || [[ "$RUN_MIXED" = 1 ]]; then
    RAW_SHA="$(logical_sha "$RAW" yes)"
    [[ "$BASE_SHA" = "$RAW_SHA" && "$(state_of "$RAW")" = RAW ]] || {
        echo "ERROR: RAW setup validation failed." >&2
        exit 1
    }
fi
if has_read_scenario sglz; then
    SGLZ_SHA="$(logical_sha "$SGLZ" yes)"
    [[ "$BASE_SHA" = "$SGLZ_SHA" && "$(state_of "$SGLZ")" = COMPRESSED ]] || {
        echo "ERROR: SGLZ setup validation failed." >&2
        exit 1
    }
fi
if has_read_scenario lz4; then
    LZ4_SHA="$(logical_sha "$LZ4" yes)"
    [[ "$BASE_SHA" = "$LZ4_SHA" && "$(state_of "$LZ4")" = COMPRESSED ]] || {
        echo "ERROR: LZ4 setup validation failed." >&2
        exit 1
    }
fi

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)"
    echo "filesystem=$(findmnt -no FSTYPE -T "$PROJECT_DIR")"
    echo "source=$(findmnt -no SOURCE -T "$PROJECT_DIR")"
    echo "vdbench_version=5.04.07"
    echo "java=$("$JAVA" -version 2>&1 | head -1)"
    echo "size=$SIZE"
    echo "size_bytes=$SIZE_BYTES"
    echo "elapsed_s=$ELAPSED"
    echo "warmup_s=$WARMUP"
    echo "repeats=$REPEATS"
    echo "threads=$THREADS"
    echo "read_workloads=$READ_WORKLOADS"
    echo "read_scenarios=$READ_SCENARIOS"
    echo "run_mixed=$RUN_MIXED"
    echo "lz4_small_read_cpu_blocks=${GPUC_LZ4_SMALL_READ_CPU_BLOCKS:-1}"
    echo "lz4_h2d_coalesce=${GPUC_H2D_COALESCE:-1}"
    echo "lz4_worker_batch_blocks=${GPUC_LZ4_WORKER_BATCH_BLOCKS:-128}"
    echo "sample_timeout_s=$SAMPLE_TIMEOUT"
    echo "cache_mode=warm buffered I/O; identical mode for every scenario"
    echo "direct=0 (GPUC RAW compact header is not O_DIRECT aligned)"
    echo "baseline_sha256=$BASE_SHA"
    echo "raw_sha256=$RAW_SHA"
    echo "sglz_sha256=$SGLZ_SHA"
    echo "lz4_sha256=$LZ4_SHA"
    echo "raw_state=$([[ -f "$RAW" ]] && state_of "$RAW" || echo not-prepared)"
    echo "sglz_state=$([[ -f "$SGLZ" ]] && state_of "$SGLZ" || echo not-prepared)"
    echo "lz4_state=$([[ -f "$LZ4" ]] && state_of "$LZ4" || echo not-prepared)"
} > "$RESULT_DIR/environment.txt"

echo "scenario,workload,repeat,iops,mb_s,resp_ms,read_resp_ms,write_resp_ms,max_resp_ms,p95_bucket_ms,p99_bucket_ms,queue_depth,host_cpu_pct,host_sys_pct,state,sha256" \
    > "$RESULT_DIR/runs.csv"

parse_output() {
    local flatfile=$1 histogram=$2 scenario=$3 workload=$4 repeat=$5 state=$6 sha=$7
    python3 - "$flatfile" "$histogram" "$RESULT_DIR/runs.csv" \
        "$scenario" "$workload" "$repeat" "$state" "$sha" <<'PY'
import csv
import re
import sys

flatfile, histogram, output, scenario, workload, repeat, state, sha = sys.argv[1:]
header = None
average = None
with open(flatfile, errors="replace") as f:
    for line in f:
        fields = line.split()
        if fields[:4] == ["tod", "timestamp", "Run", "Interval"]:
            header = fields
        elif header and len(fields) == len(header) and fields[3].startswith("avg_"):
            average = dict(zip(header, fields))
if average is None:
    raise SystemExit(f"no Vdbench average row in {flatfile}")

percentiles = {}
in_histogram = False
with open(histogram, errors="replace") as f:
    for line in f:
        stripped = line.strip()
        if stripped in {
            "Reads and writes:",
            "Only reads done for this workload:",
            "Only writes done for this workload:",
        }:
            in_histogram = True
            continue
        if in_histogram and stripped in {"Reads:", "Writes:"}:
            break
        if not in_histogram:
            continue
        match = re.match(
            r"^([0-9.]+)\s+<\s+([0-9.]+|max)\s+([0-9,]+)\s+"
            r"([0-9.]+)\s+([0-9.]+)",
            stripped,
        )
        if not match:
            continue
        upper, cumulative = match.group(2), float(match.group(5))
        for target in (95, 99):
            if target not in percentiles and cumulative >= target:
                percentiles[target] = (
                    float(average["resp_max"]) if upper == "max" else float(upper)
                )

row = [
    scenario, workload, repeat,
    average["rate"], average["MB/sec"], average["resp"],
    average["read_resp"], average["write_resp"], average["resp_max"],
    f"{percentiles.get(95, float(average['resp_max'])):.6f}",
    f"{percentiles.get(99, float(average['resp_max'])):.6f}",
    average["queue_depth"], average["cpu_used"], average["cpu_kernel"],
    state, sha,
]
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(row)
print(
    f"[PASS] {scenario:9s} {workload:11s} repeat={repeat} "
    f"iops={float(row[3]):.1f} MB/s={float(row[4]):.1f} "
    f"resp={float(row[5]):.3f} ms"
)
PY
}

warm_file() {
    local path=$1 preload=$2
    if [[ -n "$preload" ]]; then
        LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
            dd if="$path" of=/dev/null bs=1M status=none
    else
        dd if="$path" of=/dev/null bs=1M status=none
    fi
}

run_one() {
    local scenario=$1 workload=$2 repeat=$3 path=$4 preload=$5
    local tag="${scenario}_${workload}_r${repeat}"
    local par="$RESULT_DIR/${tag}.par"
    local outdir="$RESULT_DIR/$tag"
    local log="$RESULT_DIR/logs/${tag}.log"
    local state sha status

    state="$(state_of "$path")"
    sha="$(logical_sha "$path" "$preload")"
    warm_file "$path" "$preload"
    sed -e "s|@LUN@|$path|g" -e "s|@SIZE@|$SIZE|g" \
        -e "s|@ELAPSED@|$ELAPSED|g" -e "s|@WARMUP@|$WARMUP|g" \
        -e "s|@THREADS@|$THREADS|g" \
        "$PROJECT_DIR/tests/vdbench/${workload}.par" > "$par"

    set +e
    if [[ -n "$preload" ]]; then
        timeout --signal=TERM --kill-after=10 "$SAMPLE_TIMEOUT" \
            env LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 GPUC_WHITELIST=html,txt \
            "$VDBENCH" -f "$par" -o "$outdir" > "$log" 2>&1
        status=$?
    else
        timeout --signal=TERM --kill-after=10 "$SAMPLE_TIMEOUT" \
            "$VDBENCH" -f "$par" -o "$outdir" > "$log" 2>&1
        status=$?
    fi
    set -e

    if [[ "$status" -ne 0 ]]; then
        echo "ERROR: $tag failed with status $status" >&2
        sed -n '1,160p' "$log" >&2
        exit 1
    fi
    # Vdbench inherits executable mode bits from its installation directory for
    # generated reports. Normalize result artifacts before they enter Git.
    find "$outdir" -type d -exec chmod 0755 {} +
    find "$outdir" -type f -exec chmod 0644 {} +
    grep -q "Vdbench execution completed successfully" "$outdir/summary.html" || {
        echo "ERROR: $tag has no successful completion marker." >&2
        exit 1
    }
    parse_output "$outdir/flatfile.html" "$outdir/histogram.html" \
        "$scenario" "$workload" "$repeat" "$state" "$sha"
}

for repeat in $(seq 1 "$REPEATS"); do
    for workload in $READ_WORKLOADS; do
        for scenario in $READ_SCENARIOS; do
            case "$scenario" in
                baseline) run_one baseline "$workload" "$repeat" "$BASE" "" ;;
                hook_raw) run_one hook_raw "$workload" "$repeat" "$RAW" yes ;;
                sglz) run_one sglz "$workload" "$repeat" "$SGLZ" yes ;;
                lz4) run_one lz4 "$workload" "$repeat" "$LZ4" yes ;;
                *) echo "ERROR: unknown read scenario: $scenario" >&2; exit 2 ;;
            esac
        done
    done

    # COMPRESSED/INLINE are immutable; mixed read/write uses fresh, independent
    # Baseline and Hook RAW files for every repeat.
    if [[ "$RUN_MIXED" = 1 ]]; then
        MIXED_BASE="$TEST_DIR/mixed_baseline.bin"
        MIXED_RAW="$TEST_DIR/mixed_raw.bin"
        cp "$BASE" "$MIXED_BASE"
        LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$BASE" "$MIXED_RAW"
        run_one baseline mixed_rw "$repeat" "$MIXED_BASE" ""
        run_one hook_raw mixed_rw "$repeat" "$MIXED_RAW" yes
        rm -f -- "$MIXED_BASE" "$MIXED_RAW"
    fi
done

# Read-only source files must be unchanged after all Vdbench samples.
[[ "$(logical_sha "$BASE" "")" = "$BASE_SHA" ]]
if has_read_scenario hook_raw || [[ "$RUN_MIXED" = 1 ]]; then
    [[ "$(logical_sha "$RAW" yes)" = "$RAW_SHA" ]]
fi
if has_read_scenario sglz; then
    [[ "$(logical_sha "$SGLZ" yes)" = "$SGLZ_SHA" ]]
fi
if has_read_scenario lz4; then
    [[ "$(logical_sha "$LZ4" yes)" = "$LZ4_SHA" ]]
fi

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv
import math
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
groups = {}
for row in rows:
    groups.setdefault((row["scenario"], row["workload"]), []).append(row)
metrics = ["iops", "mb_s", "resp_ms", "p95_bucket_ms", "p99_bucket_ms"]
with open(sys.argv[2], "w", newline="") as f:
    out = csv.writer(f, lineterminator="\n")
    header = ["scenario", "workload", "n"]
    for metric in metrics:
        header += [f"{metric}_mean", f"{metric}_ci95"]
    out.writerow(header)
    for key, items in sorted(groups.items()):
        row = [*key, len(items)]
        for metric in metrics:
            values = [float(item[metric]) for item in items]
            mean = statistics.mean(values)
            ci95 = (
                1.96 * statistics.stdev(values) / math.sqrt(len(values))
                if len(values) > 1 else 0.0
            )
            row += [f"{mean:.6f}", f"{ci95:.6f}"]
        out.writerow(row)
PY

echo "[OK] Vdbench benchmark complete: $RESULT_DIR"
