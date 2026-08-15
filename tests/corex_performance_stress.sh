#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COREX_HOME="${COREX_HOME:-/usr/local/corex-4.4.0}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/corex_perf_${RUN_ID}}"
PERF_MIB="${GPUC_PERF_MIB:-1024}"
PERF_ITERATIONS="${GPUC_PERF_ITERATIONS:-3}"
STRESS_MIB="${GPUC_STRESS_MIB:-16384}"
STRESS_ITERATIONS="${GPUC_STRESS_ITERATIONS:-4}"
E2E_MIB="${GPUC_E2E_MIB:-1024}"
E2E_READS="${GPUC_E2E_READS:-3}"
BENCH="$PROJECT_DIR/bin/benchmark_sglz_transport"
WORK_DIR="$(mktemp -d "$PROJECT_DIR/gpuc-corex-stress-XXXXXX")"

cleanup() {
    rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

export PATH="$COREX_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$COREX_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
mkdir -p "$RESULT_DIR"

command -v ixsmi >/dev/null 2>&1 || { echo "ixsmi not found" >&2; exit 1; }
ixsmi > "$RESULT_DIR/ixsmi_before.txt"
make -C "$PROJECT_DIR" GPU_PLATFORM=corex bin/benchmark_sglz_transport >/dev/null

cat > "$RESULT_DIR/environment.txt" <<EOF
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
cpu=$(lscpu | awk -F: '/Model name/{sub(/^[[:space:]]+/,"",$2); print $2; exit}')
corex_home=$COREX_HOME
perf_mib=$PERF_MIB
perf_iterations=$PERF_ITERATIONS
stress_mib=$STRESS_MIB
stress_iterations=$STRESS_ITERATIONS
e2e_mib=$E2E_MIB
e2e_reads=$E2E_READS
EOF

GPUC_SGLZ_COALESCE=0 GPUC_PERF_MIB="$PERF_MIB" \
    GPUC_PERF_ITERATIONS="$PERF_ITERATIONS" "$BENCH" > "$RESULT_DIR/baseline.csv"
GPUC_SGLZ_COALESCE=1 GPUC_PERF_MIB="$PERF_MIB" \
    GPUC_PERF_ITERATIONS="$PERF_ITERATIONS" "$BENCH" > "$RESULT_DIR/optimized.csv"

GPUC_SGLZ_COALESCE=1 GPUC_PERF_MIB="$STRESS_MIB" \
    GPUC_PERF_ITERATIONS="$STRESS_ITERATIONS" "$BENCH" > "$RESULT_DIR/stress.csv"

# Large-file daemon/Hook path: create RAW, compress on GPU, then repeatedly
# read the logical content and verify its SHA-256.
make -C "$PROJECT_DIR" GPU_PLATFORM=corex bin/libgpuhook.so \
    bin/gpu_compress_daemon >/dev/null
mkdir -p "$WORK_DIR/data"
managed="$WORK_DIR/data/large-zero.bin"
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    dd if=/dev/zero of="$managed" bs=1M count="$E2E_MIB" status=none
before_sha="$(LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    dd if="$managed" bs=1M status=none | sha256sum | awk '{print $1}')"
SECONDS=0
"$PROJECT_DIR/bin/gpu_compress_daemon" "$WORK_DIR/data" > "$RESULT_DIR/daemon.log" 2>&1
daemon_seconds="$SECONDS"
for read_id in $(seq 1 "$E2E_READS"); do
    after_sha="$(LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        dd if="$managed" bs=1M status=none | sha256sum | awk '{print $1}')"
    [[ "$after_sha" == "$before_sha" ]] || {
        echo "large-file SHA mismatch on read $read_id" >&2
        exit 1
    }
done
printf 'logical_mib=%s\nreads=%s\ndaemon_seconds=%s\nsha256=%s\nstatus=PASS\n' \
    "$E2E_MIB" "$E2E_READS" "$daemon_seconds" "$before_sha" \
    > "$RESULT_DIR/e2e_large_file.txt"
ixsmi > "$RESULT_DIR/ixsmi_after.txt"

python3 - "$RESULT_DIR" <<'PY'
import csv, pathlib, sys
root = pathlib.Path(sys.argv[1])
def row(name):
    with (root / name).open() as f:
        return next(csv.DictReader(f))
b, o, s = row("baseline.csv"), row("optimized.csv"), row("stress.csv")
bc, oc = float(b["compress_mib_s"]), float(o["compress_mib_s"])
bd, od = float(b["decompress_mib_s"]), float(o["decompress_mib_s"])
summary = [
    "correctness=PASS",
    f"baseline_compress_mib_s={bc:.3f}",
    f"optimized_compress_mib_s={oc:.3f}",
    f"compress_speedup={oc / bc:.3f}",
    f"baseline_decompress_mib_s={bd:.3f}",
    f"optimized_decompress_mib_s={od:.3f}",
    f"decompress_speedup={od / bd:.3f}",
    f"stress_checked_blocks={s['checked_blocks']}",
    f"stress_logical_mib={int(s['logical_mib']) * int(s['iterations'])}",
    "stress_status=PASS",
    "large_file_e2e=PASS",
]
(root / "summary.txt").write_text("\n".join(summary) + "\n")
print("\n".join(summary))
PY

sha256sum "$PROJECT_DIR/src/gpu_compress.cu" \
    "$PROJECT_DIR/tests/benchmark_sglz_transport.c" \
    "$PROJECT_DIR/tests/corex_performance_stress.sh" \
    > "$RESULT_DIR/SOURCE_MANIFEST.sha256"

echo "[PASS] CoreX performance and stress evidence: $RESULT_DIR"
