#!/usr/bin/env bash
set -euo pipefail

# Intel PCM needs root to access MSR, ACPI MCFG and server uncore PCI space.
# Run this script explicitly with sudo; never place a password in the command.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/pcm_dram_${RUN_ID}}"
PCM="${GPUC_PCM_MEMORY:-$PROJECT_DIR/third_party/manual/pcm/build/bin/pcm-memory}"
TEST_BIN="$PROJECT_DIR/bin/test_cpu_offload"
DURATION="${GPUC_RUNTIME:-10}"
REPEATS="${GPUC_REPEATS:-5}"
WORKERS="${GPUC_BUSINESS_WORKERS:-4}"
DECOMP_CPU="${GPUC_DECOMP_CPU:-0}"
TARGET_MIB_S="${GPUC_TARGET_MIB_S:-4096}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-512}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-128}"
export GPUC_WORKER_CPU="${GPUC_WORKER_CPU:-$DECOMP_CPU}"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Intel PCM requires root on this server." >&2
    echo "Run: sudo env GPUC_RESULT_DIR=results/local/pcm_dram bash tests/pcm_dram_offload.sh" >&2
    exit 2
fi
[[ -x "$PCM" ]] || { echo "ERROR: missing PCM binary: $PCM" >&2; exit 2; }
[[ -x "$TEST_BIN" ]] || {
    echo "ERROR: build bin/test_cpu_offload before invoking sudo." >&2
    exit 2
}
[[ "$DURATION" =~ ^[1-9][0-9]*$ && "$REPEATS" =~ ^[1-9][0-9]*$ ]] || {
    echo "ERROR: GPUC_RUNTIME and GPUC_REPEATS must be positive integers." >&2
    exit 2
}

mkdir -p "$RESULT_DIR/raw"

restore_owner() {
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown -R "$SUDO_UID:$SUDO_GID" "$RESULT_DIR" 2>/dev/null || true
    fi
}
trap restore_owner EXIT

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)"
    echo "pcm_commit=$(git -C "$PROJECT_DIR/third_party/manual/pcm" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "duration_s=$DURATION"
    echo "repeats=$REPEATS"
    echo "business_workers=$WORKERS"
    echo "target_mib_s=$TARGET_MIB_S"
    echo "decomp_cpu=$DECOMP_CPU"
    echo "gpu_worker_cpu=$GPUC_WORKER_CPU"
    echo "workset_mib=$WORKSET_MIB"
    echo "batch_blocks=$BATCH_BLOCKS"
    echo "scope=whole-system IMC bandwidth; only complete steady-state 1s intervals"
    echo "unit=PCM MB/s"
} > "$RESULT_DIR/environment.txt"

echo "scenario,repeat,dram_read_mb_s,dram_write_mb_s,dram_total_mb_s,elapsed_s,business_ops_s,decomp_mib_s,user_cpu_s,sys_cpu_s,worker_user_s,worker_sys_s,maxrss_kib" \
    > "$RESULT_DIR/runs.csv"

parse_sample() {
    local scenario=$1 repeat=$2 pcm_csv=$3 app_output=$4 phase_file=$5
    python3 - "$scenario" "$repeat" "$pcm_csv" "$app_output" "$phase_file" "$RESULT_DIR/runs.csv" <<'PY'
import csv
import datetime
import sys

scenario, repeat, pcm_path, app_path, phase_path, output = sys.argv[1:]

rows = [row for row in csv.reader(open(pcm_path, errors="replace")) if row]
phase = {}
for label, value in csv.reader(open(phase_path)):
    phase[label] = float(value)
samples = []
for row in rows:
    try:
        timestamp = datetime.datetime.strptime(
            f"{row[0].strip()} {row[1].strip()}", "%Y-%m-%d %H:%M:%S.%f"
        ).replace(tzinfo=datetime.timezone.utc).timestamp()
        tail = [float(value.strip()) for value in row[-3:]]
    except (ValueError, IndexError):
        continue
    # A timestamp is the end of the preceding 1-second PCM interval. Keep only
    # intervals wholly inside the application's measured steady-state window.
    if timestamp >= phase["start"] + 1.05 and timestamp <= phase["end"]:
        samples.append(tail)
if not samples:
    raise SystemExit(f"no complete steady-state PCM intervals in {pcm_path}")
pcm_values = [sum(values) / len(values) for values in zip(*samples)]

lines = [line.strip() for line in open(app_path, errors="replace") if line.strip()]
app = None
for line in reversed(lines):
    values = line.split(",")
    if len(values) == 25 and values[0] == scenario:
        app = values
        break
if app is None:
    raise SystemExit(f"no test_cpu_offload row in {app_path}")

names = [
    "scenario", "elapsed", "workers", "business", "decomp", "user", "system",
    "submit_user", "submit_system", "maxrss", "minflt", "majflt", "nvcsw",
    "nivcsw", "calls", "queue_ms", "pack_ms", "h2d_ms", "kernel_ms",
    "d2h_ms", "unpack_ms", "total_ms", "worker_user", "worker_system", "pinned",
]
record = dict(zip(names, app))
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow([
        scenario,
        repeat,
        *[f"{value:.6f}" for value in pcm_values],
        record["elapsed"],
        record["business"],
        record["decomp"],
        record["user"],
        record["system"],
        record["worker_user"],
        record["worker_system"],
        record["maxrss"],
    ])
print(
    f"[PASS] {scenario:8s} repeat={repeat} "
    f"DRAM={pcm_values[2]:.2f} MB/s "
    f"read={pcm_values[0]:.2f} write={pcm_values[1]:.2f} intervals={len(samples)}"
)
PY
}

scenarios=(baseline cpu gpu)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 3 ))
    for index in 0 1 2; do
        scenario="${scenarios[$(( (index + shift) % 3 ))]}"
        tag="${scenario}_r${repeat}"
        pcm_csv="$RESULT_DIR/raw/${tag}_pcm.csv"
        app_output="$RESULT_DIR/raw/${tag}_app.txt"
        diagnostics="$RESULT_DIR/raw/${tag}_pcm.stderr"
        phase_file="$RESULT_DIR/raw/${tag}_phase.csv"
        ready_file="$RESULT_DIR/raw/${tag}.ready"
        start_file="$RESULT_DIR/raw/${tag}.start"

        rm -f "$ready_file" "$start_file" "$phase_file"
        "$PCM" 1 -f -silent -csv="$pcm_csv" -- \
            /usr/bin/env \
            GPUC_WORKSET_MIB="$WORKSET_MIB" \
            GPUC_BATCH_BLOCKS="$BATCH_BLOCKS" \
            GPUC_READY_FILE="$ready_file" \
            GPUC_START_FILE="$start_file" \
            GPUC_PHASE_FILE="$phase_file" \
            GPUC_WORKER_CPU="$GPUC_WORKER_CPU" \
            "$TEST_BIN" "$scenario" "$DURATION" "$WORKERS" \
            "$DECOMP_CPU" "$TARGET_MIB_S" \
            > "$app_output" 2> "$diagnostics" &
        pcm_pid=$!
        for _ in $(seq 1 1200); do
            [[ -e "$ready_file" ]] && break
            kill -0 "$pcm_pid" 2>/dev/null || break
            sleep 0.05
        done
        if [[ ! -e "$ready_file" ]]; then
            wait "$pcm_pid" || true
            echo "ERROR: benchmark did not reach ready state: $diagnostics" >&2
            exit 1
        fi
        sleep 1.2
        : > "$start_file"
        wait "$pcm_pid"

        parse_sample "$scenario" "$repeat" "$pcm_csv" "$app_output" "$phase_file"
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
    groups.setdefault(row["scenario"], []).append(row)

metrics = [
    "dram_read_mb_s",
    "dram_write_mb_s",
    "dram_total_mb_s",
    "business_ops_s",
    "decomp_mib_s",
    "user_cpu_s",
    "sys_cpu_s",
    "worker_user_s",
    "worker_sys_s",
    "maxrss_kib",
]
with open(sys.argv[2], "w", newline="") as f:
    writer = csv.writer(f, lineterminator="\n")
    header = ["scenario", "n"]
    for metric in metrics:
        header += [f"{metric}_mean", f"{metric}_ci95"]
    writer.writerow(header)
    for scenario in ("baseline", "cpu", "gpu"):
        items = groups.get(scenario, [])
        row = [scenario, len(items)]
        for metric in metrics:
            values = [float(item[metric]) for item in items]
            mean = statistics.mean(values)
            ci95 = (
                1.96 * statistics.stdev(values) / math.sqrt(len(values))
                if len(values) > 1 else 0.0
            )
            row += [f"{mean:.6f}", f"{ci95:.6f}"]
        writer.writerow(row)
PY

echo "[OK] PCM DRAM experiment complete: $RESULT_DIR"
