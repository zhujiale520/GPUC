#!/usr/bin/env bash
set -euo pipefail

# Read-only scan over actual system log and ELF bytes. Source bytes are repeated
# deterministically only to make the timed corpus large enough.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/real_scan_${RUN_ID}}"
RUNTIME="${GPUC_RUNTIME:-5}"
REPEATS="${GPUC_REPEATS:-5}"
CORPUS_MIB="${GPUC_CORPUS_MIB:-64}"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
SCANNER="$PROJECT_DIR/bin/scan_workload"
TEST_DIR="$(mktemp -d /tmp/gpuc-real-scan-XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

for path in "$HOOK" "$DAEMON" "$SCANNER"; do
    [[ -e "$path" ]] || { echo "ERROR: missing build artifact: $path" >&2; exit 2; }
done
mkdir -p "$RESULT_DIR/raw" "$TEST_DIR/compressed"
LOG_SOURCE=/var/log/dpkg.log
[[ -r "$LOG_SOURCE" && -s "$LOG_SOURCE" ]] || LOG_SOURCE=/var/lib/dpkg/status
ELF_SOURCE=/usr/bin/bash
[[ -r "$ELF_SOURCE" ]] || ELF_SOURCE=/bin/sh
PLAIN="$TEST_DIR/corpus.bin"
COMPRESSED="$TEST_DIR/compressed/corpus.bin"

python3 - "$LOG_SOURCE" "$ELF_SOURCE" "$PLAIN" "$CORPUS_MIB" <<'PY'
import sys
log_path, elf_path, output, size_mib = sys.argv[1:]
parts = [open(log_path, "rb").read(), open(elf_path, "rb").read()]
target = int(size_mib) * 1024 * 1024
with open(output, "wb") as f:
    written = 0
    while written < target:
        for marker, part in zip((b"\n--- REAL LOG ---\n", b"\n--- ELF BINARY ---\n"), parts):
            data = (marker + part)[:target-written]
            f.write(data)
            written += len(data)
            if written >= target:
                break
PY

LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$PLAIN" "$COMPRESSED"
GPUC_ALGO=lz4 "$DAEMON" "$TEST_DIR/compressed" > "$RESULT_DIR/daemon.log" 2>&1
plain_sha="$(sha256sum "$PLAIN" | awk '{print $1}')"
logical_sha="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 dd if="$COMPRESSED" bs=1M status=none | sha256sum | awk '{print $1}')"
[[ "$plain_sha" == "$logical_sha" ]] || { echo "ERROR: compressed corpus checksum mismatch" >&2; exit 1; }

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)"
    echo "log_source=$LOG_SOURCE"
    echo "log_sha256=$(sha256sum "$LOG_SOURCE" | awk '{print $1}')"
    echo "elf_source=$ELF_SOURCE"
    echo "elf_sha256=$(sha256sum "$ELF_SOURCE" | awk '{print $1}')"
    echo "corpus_mib=$CORPUS_MIB"
    echo "corpus_sha256=$plain_sha"
    echo "corpus_construction=real source bytes repeated deterministically for stable timing"
    echo "runtime_s=$RUNTIME"
    echo "repeats=$REPEATS"
    echo "compressed_allocated_bytes=$(du -B1 "$COMPRESSED" | awk '{print $1}')"
} > "$RESULT_DIR/environment.txt"

echo "scenario,repeat,elapsed_s,bytes,scans,mib_s,scans_s,p99_scan_ms,cpu_cores,hash,marker_hits,logical_bytes,maxrss_kib" \
    > "$RESULT_DIR/runs.csv"

run_one() {
    local scenario=$1 repeat=$2
    local output="$RESULT_DIR/raw/${scenario}_r${repeat}.csv"
    case "$scenario" in
        baseline) "$SCANNER" "$PLAIN" "$RUNTIME" > "$output" ;;
        cpu) LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 GPUCOMPRESS_BACKEND=cpu \
             "$SCANNER" "$COMPRESSED" "$RUNTIME" > "$output" ;;
        gpu) LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 GPUCOMPRESS_BACKEND=gpu \
             "$SCANNER" "$COMPRESSED" "$RUNTIME" > "$output" ;;
    esac
    python3 - "$scenario" "$repeat" "$output" "$RESULT_DIR/runs.csv" <<'PY'
import csv, sys
scenario, repeat, source, output = sys.argv[1:]
rows = [r for r in csv.reader(open(source)) if len(r) == 11]
if not rows: raise SystemExit(f"missing scanner output: {source}")
r = rows[-1]
with open(output, "a", newline="") as f:
    csv.writer(f, lineterminator="\n").writerow([scenario, repeat, *r])
print(f"[PASS] {scenario:8s} repeat={repeat} scan={float(r[3]):.2f} MiB/s "
      f"p99={float(r[5]):.1f} ms cpu={float(r[6]):.3f} cores")
PY
}

scenarios=(baseline cpu gpu)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 3 ))
    for index in 0 1 2; do
        run_one "${scenarios[$(( (index + shift) % 3 ))]}" "$repeat"
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv, math, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
metrics = ["mib_s", "scans_s", "p99_scan_ms", "cpu_cores", "maxrss_kib"]
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f, lineterminator="\n")
    w.writerow(["scenario", "n"] + [x for m in metrics for x in (f"{m}_mean", f"{m}_ci95")])
    for name in ("baseline", "cpu", "gpu"):
        items = [r for r in rows if r["scenario"] == name]
        out = [name, len(items)]
        for metric in metrics:
            values = [float(r[metric]) for r in items]
            mean = statistics.mean(values)
            ci = 1.96 * statistics.stdev(values) / math.sqrt(len(values)) if len(values) > 1 else 0
            out += [f"{mean:.6f}", f"{ci:.6f}"]
        w.writerow(out)
PY
echo "[OK] Real log/ELF scan complete: $RESULT_DIR"
