#!/usr/bin/env bash
set -euo pipefail

# Fair ablation of the compressed read path.
# One immutable COMPRESSED input is reused; only libgpuhook.so is rebuilt.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/ablation_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-ablation-XXXXXX)"
SIZE="${GPUC_SIZE:-512M}"
RUNTIME="${GPUC_RUNTIME:-10}"
REPEATS="${GPUC_REPEATS:-5}"
BS="${GPUC_BS:-128k}"
DIRECT="${GPUC_DIRECT:-0}"
TEST_FILE="$TEST_DIR/compressed.bin"
INPUT_FILE="$TEST_DIR/input.bin"

mkdir -p "$RESULT_DIR"
[[ "$DIRECT" == 0 ]] || { echo "[ERROR] GPUC compact format does not support true O_DIRECT; use GPUC_DIRECT=0" >&2; exit 2; }
trap 'rm -rf -- "$TEST_DIR"; rm -f "$PROJECT_DIR/bin/libgpuhook.so"; make -C "$PROJECT_DIR" bin/libgpuhook.so >/dev/null' EXIT

state_of() {
    python3 - "$1" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    h = f.read(25)
print("COMPRESSED" if len(h) == 25 and h[:4] == b"CUPG" and h[24] == 1 else "INVALID")
PY
}

logical_sha() {
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        dd if="$1" bs=1M status=none | sha256sum | awk '{print $1}'
}

build_variant() {
    local flags="$1"
    rm -f "$PROJECT_DIR/bin/libgpuhook.so"
    make -C "$PROJECT_DIR" ABLATION_FLAGS="$flags" bin/libgpuhook.so >/dev/null
}

echo "[SETUP] Generating $SIZE deterministic compressible input..."
python3 - "$INPUT_FILE" "$SIZE" <<'PY'
import os, sys
path, size = sys.argv[1], sys.argv[2].upper()
units = {"K": 1<<10, "M": 1<<20, "G": 1<<30}
n = int(size[:-1]) * units[size[-1]]
with open(path, "wb", buffering=1024*1024) as f:
    for page in range(n // 4096):
        f.write(bytes([1 + (page * 37) % 251]) * 4096)
PY
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    dd if="$INPUT_FILE" of="$TEST_FILE" bs=1M status=none
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TEST_DIR" >/dev/null

input_sha="$(sha256sum "$INPUT_FILE" | awk '{print $1}')"
test_sha="$(logical_sha "$TEST_FILE")"
state="$(state_of "$TEST_FILE")"
[[ "$state" == COMPRESSED && "$input_sha" == "$test_sha" ]]
apparent="$(stat -c %s "$TEST_FILE")"
allocated="$(du -B1 "$TEST_FILE" | awk '{print $1}')"

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
fio=$(fio --version)
gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)
size=$SIZE
runtime=$RUNTIME
repeats=$REPEATS
bs=$BS
direct=$DIRECT
input_sha256=$input_sha
state=$state
apparent_bytes=$apparent
allocated_bytes=$allocated
EOF

echo "variant,flags,repeat,bw_mib_s,iops,mean_lat_us,error,state,sha256" > "$RESULT_DIR/runs.csv"

variants=(
    "full|"
    "no_ioring|-DGPUC_NO_IOURING"
    "no_readahead|-DGPUC_NO_READAHEAD"
    "no_pipeline|-DGPUC_NO_PIPELINE"
    "no_pinned|-DGPUC_NO_PINNED"
    "no_batch|-DGPUC_NO_BATCH"
    "minimal|-DGPUC_NO_BATCH -DGPUC_NO_PIPELINE -DGPUC_NO_READAHEAD -DGPUC_NO_IOURING -DGPUC_NO_PINNED"
)

for spec in "${variants[@]}"; do
    variant="${spec%%|*}"
    flags="${spec#*|}"
    echo "[BUILD] $variant flags='$flags'"
    build_variant "$flags"
    [[ "$(state_of "$TEST_FILE")" == COMPRESSED ]]
    [[ "$(logical_sha "$TEST_FILE")" == "$input_sha" ]]

    for repeat in $(seq 1 "$REPEATS"); do
        json="$RESULT_DIR/${variant}_r${repeat}.json"
        LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
            fio --name="$variant" --filename="$TEST_FILE" --size="$SIZE" \
                --bs="$BS" --rw=read --runtime="$RUNTIME" --time_based \
                --direct="$DIRECT" --invalidate=0 --ioengine=sync --numjobs=1 \
                --group_reporting --output-format=json > "$json" 2>/dev/null
        python3 - "$json" "$RESULT_DIR/runs.csv" "$variant" "$flags" "$repeat" "$state" "$input_sha" <<'PY'
import csv, json, sys
jpath, csvpath, variant, flags, repeat, state, sha = sys.argv[1:]
d = json.load(open(jpath))
r = d["jobs"][0]["read"]
lat = r.get("lat_ns", {}).get("mean", 0) / 1000
row = [variant, flags, repeat, r["bw"]/1024, r["iops"], lat, d["jobs"][0]["error"], state, sha]
with open(csvpath, "a", newline="") as f:
    csv.writer(f).writerow(row)
print(f"{variant:14s} repeat={repeat} bw={r['bw']/1024:9.1f} MiB/s")
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv, math, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
groups = {}
for r in rows:
    groups.setdefault((r["variant"], r["flags"]), []).append(float(r["bw_mib_s"]))
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["variant","flags","n","mean_mib_s","stddev_mib_s","ci95_mib_s","drop_vs_full_pct"])
    full = statistics.mean(groups[("full", "")])
    for key, vals in groups.items():
        mean = statistics.mean(vals)
        std = statistics.stdev(vals) if len(vals) > 1 else 0
        ci = 1.96 * std / math.sqrt(len(vals)) if len(vals) > 1 else 0
        w.writerow([*key, len(vals), f"{mean:.3f}", f"{std:.3f}", f"{ci:.3f}",
                    f"{(full-mean)/full*100:.3f}"])
        print(f"{key[0]:14s} mean={mean:9.1f} std={std:7.1f} 95%CI=±{ci:6.1f} drop={(full-mean)/full*100:7.2f}%")
PY

echo "[OK] $RESULT_DIR"
