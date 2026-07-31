#!/usr/bin/env bash
set -euo pipefail

# Whole-system Intel IMC traffic during equal-throughput CPU/GPU LZ4 compression.
# PCM requires root. The benchmark waits until PCM has initialized, then records
# only complete one-second intervals inside the steady-state phase.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/pcm_dram_compress_${RUN_ID}}"
PCM="${GPUC_PCM_MEMORY:-$PROJECT_DIR/third_party/manual/pcm/build/bin/pcm-memory}"
BENCH="$PROJECT_DIR/bin/benchmark_lz4_compress"
DURATION="${GPUC_RUNTIME:-10}"
REPEATS="${GPUC_REPEATS:-5}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-512}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-32}"
TARGET_MIB_S="${GPUC_TARGET_MIB_S:-1024}"

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Intel PCM requires root on this server." >&2
    echo "Run: sudo env GPUC_RESULT_DIR=\"$PROJECT_DIR/results/local/pcm_dram_compress\" bash tests/pcm_dram_compress.sh" >&2
    exit 2
fi
[[ -x "$PCM" ]] || { echo "ERROR: missing PCM binary: $PCM" >&2; exit 2; }
[[ -x "$BENCH" ]] || { echo "ERROR: build $BENCH before sudo." >&2; exit 2; }
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
    echo "cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)"
    echo "runtime_s=$DURATION"
    echo "repeats=$REPEATS"
    echo "workset_mib=$WORKSET_MIB"
    echo "block_kib=128"
    echo "batch_blocks=$BATCH_BLOCKS"
    echo "target_mib_s=$TARGET_MIB_S"
    echo "scope=whole-system IMC bandwidth; complete steady-state 1s intervals"
} > "$RESULT_DIR/environment.txt"

echo "scenario,repeat,dram_read_mb_s,dram_write_mb_s,dram_total_mb_s,intervals,elapsed_s,mib_s,ratio,user_s,sys_s,cpu_cores,maxrss_kib" \
    > "$RESULT_DIR/runs.csv"

parse_sample() {
    python3 - "$1" "$2" "$3" "$4" "$5" "$RESULT_DIR/runs.csv" <<'PY'
import csv
import datetime
import sys

scenario, repeat, pcm_path, app_path, phase_path, output = sys.argv[1:]
phase = {k: float(v) for k, v in csv.reader(open(phase_path))}
samples = []
for row in csv.reader(open(pcm_path, errors="replace")):
    try:
        stamp = datetime.datetime.strptime(
            f"{row[0].strip()} {row[1].strip()}", "%Y-%m-%d %H:%M:%S.%f"
        ).replace(tzinfo=datetime.timezone.utc).timestamp()
        tail = [float(v.strip()) for v in row[-3:]]
    except (ValueError, IndexError):
        continue
    if stamp >= phase["start"] + 1.05 and stamp <= phase["end"]:
        samples.append(tail)
if not samples:
    raise SystemExit(f"no complete steady-state PCM intervals in {pcm_path}")
dram = [sum(v) / len(v) for v in zip(*samples)]
app_rows = [r for r in csv.reader(open(app_path)) if len(r) == 16]
if not app_rows:
    raise SystemExit(f"missing benchmark row: {app_path}")
r = app_rows[-1]
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow(
        [scenario, repeat, *[f"{v:.6f}" for v in dram], len(samples),
         r[1], r[2], r[5], r[6], r[7], r[8], r[9]]
    )
print(f"[PASS] {scenario:3s} repeat={repeat} DRAM={dram[2]:.2f} MB/s "
      f"read={dram[0]:.2f} write={dram[1]:.2f} intervals={len(samples)}")
PY
}

for repeat in $(seq 1 "$REPEATS"); do
    if (( repeat % 2 )); then order="cpu gpu"; else order="gpu cpu"; fi
    for scenario in $order; do
        tag="${scenario}_r${repeat}"
        pcm_csv="$RESULT_DIR/raw/${tag}_pcm.csv"
        app="$RESULT_DIR/raw/${tag}_app.csv"
        diagnostics="$RESULT_DIR/raw/${tag}_pcm.stderr"
        phase="$RESULT_DIR/raw/${tag}_phase.csv"
        ready="$RESULT_DIR/raw/${tag}.ready"
        start="$RESULT_DIR/raw/${tag}.start"
        rm -f "$ready" "$start" "$phase"

        "$PCM" 1 -f -silent -csv="$pcm_csv" -- /usr/bin/env \
            GPUC_TARGET_MIB_S="$TARGET_MIB_S" \
            GPUC_READY_FILE="$ready" GPUC_START_FILE="$start" GPUC_PHASE_FILE="$phase" \
            "$BENCH" "$scenario" "$DURATION" "$WORKSET_MIB" "$BATCH_BLOCKS" \
            > "$app" 2> "$diagnostics" &
        pcm_pid=$!
        for _ in $(seq 1 1200); do
            [[ -e "$ready" ]] && break
            kill -0 "$pcm_pid" 2>/dev/null || break
            sleep 0.05
        done
        if [[ ! -e "$ready" ]]; then
            wait "$pcm_pid" || true
            echo "ERROR: benchmark did not reach ready state: $diagnostics" >&2
            exit 1
        fi
        sleep 1.2
        : > "$start"
        wait "$pcm_pid"
        parse_sample "$scenario" "$repeat" "$pcm_csv" "$app" "$phase"
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv
import math
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
metrics = ["dram_read_mb_s", "dram_write_mb_s", "dram_total_mb_s",
           "mib_s", "ratio", "user_s", "sys_s", "cpu_cores", "maxrss_kib"]
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scenario", "n"] + [x for m in metrics for x in (f"{m}_mean", f"{m}_ci95")])
    for name in ("cpu", "gpu"):
        items = [r for r in rows if r["scenario"] == name]
        out = [name, len(items)]
        for metric in metrics:
            values = [float(r[metric]) for r in items]
            mean = statistics.mean(values)
            ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values)) if len(values) > 1 else 0
            out += [f"{mean:.6f}", f"{ci:.6f}"]
        w.writerow(out)
PY

echo "[OK] PCM compression DRAM experiment complete: $RESULT_DIR"
