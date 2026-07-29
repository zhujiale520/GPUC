#!/usr/bin/env bash
set -euo pipefail

# Sweep Hook read-ahead/decompression batch size on one immutable compressed file.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/batch_size_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-batch-XXXXXX)"
SIZE="${GPUC_SIZE:-512M}"
RUNTIME="${GPUC_RUNTIME:-10}"
REPEATS="${GPUC_REPEATS:-5}"
BS="${GPUC_BS:-128k}"
JOBS="${GPUC_JOBS:-1}"
DIRECT="${GPUC_DIRECT:-0}"
BATCH_LIST="${GPUC_BATCH_LIST:-1 2 4 8 16 32}"
INPUT="$TEST_DIR/input.bin"
COMPRESSED="$TEST_DIR/compressed.bin"

mkdir -p "$RESULT_DIR"
[[ "$DIRECT" == 0 ]] || { echo "[ERROR] GPUC compact format does not support true O_DIRECT; use GPUC_DIRECT=0" >&2; exit 2; }
trap 'rm -rf -- "$TEST_DIR"; rm -f "$PROJECT_DIR/bin/libgpuhook.so"; make -C "$PROJECT_DIR" bin/libgpuhook.so >/dev/null' EXIT

state_of() {
    python3 - "$1" <<'PY'
import sys
with open(sys.argv[1], "rb") as f: h=f.read(25)
print("COMPRESSED" if len(h)==25 and h[:4]==b"CUPG" and h[24]==1 else "INVALID")
PY
}

logical_sha() {
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        dd if="$1" bs=1M status=none | sha256sum | awk '{print $1}'
}

echo "[SETUP] Generating $SIZE deterministic nonzero input..."
python3 - "$INPUT" "$SIZE" <<'PY'
import sys
path, size = sys.argv[1], sys.argv[2].upper()
mul={"K":1<<10,"M":1<<20,"G":1<<30}; n=int(size[:-1])*mul[size[-1]]
with open(path,"wb",buffering=1<<20) as f:
    for p in range(n//4096): f.write(bytes([1+(p*37)%251])*4096)
PY
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    dd if="$INPUT" of="$COMPRESSED" bs=1M status=none
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TEST_DIR" >/dev/null

sha="$(sha256sum "$INPUT" | awk '{print $1}')"
[[ "$(state_of "$COMPRESSED")" == COMPRESSED ]]
[[ "$(logical_sha "$COMPRESSED")" == "$sha" ]]

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
jobs=$JOBS
direct=$DIRECT
batch_list=$BATCH_LIST
sha256=$sha
state=$(state_of "$COMPRESSED")
apparent_bytes=$(stat -c %s "$COMPRESSED")
allocated_bytes=$(du -B1 "$COMPRESSED" | awk '{print $1}')
EOF
echo "batch_size,repeat,bw_mib_s,iops,mean_lat_us,error,state,sha256" > "$RESULT_DIR/runs.csv"

for batch in $BATCH_LIST; do
    echo "[BUILD] MAX_BATCH_BLOCKS=$batch"
    rm -f "$PROJECT_DIR/bin/libgpuhook.so"
    make -C "$PROJECT_DIR" ABLATION_FLAGS="-DMAX_BATCH_BLOCKS=$batch" \
        bin/libgpuhook.so >/dev/null
    [[ "$(logical_sha "$COMPRESSED")" == "$sha" ]]
    for repeat in $(seq 1 "$REPEATS"); do
        json="$RESULT_DIR/batch_${batch}_r${repeat}.json"
        LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
            fio --name="batch_$batch" --filename="$COMPRESSED" --size="$SIZE" \
                --bs="$BS" --rw=read --runtime="$RUNTIME" --time_based \
                --direct="$DIRECT" --invalidate=0 --ioengine=sync --numjobs="$JOBS" \
                --group_reporting --output-format=json > "$json" 2>/dev/null
        python3 - "$json" "$RESULT_DIR/runs.csv" "$batch" "$repeat" "$sha" <<'PY'
import csv,json,sys
jpath,csvpath,batch,repeat,sha=sys.argv[1:]
d=json.load(open(jpath)); r=d["jobs"][0]["read"]
lat=r.get("lat_ns",{}).get("mean",0)/1000
with open(csvpath,"a",newline="") as f:
    csv.writer(f).writerow([batch,repeat,r["bw"]/1024,r["iops"],lat,d["jobs"][0]["error"],"COMPRESSED",sha])
print(f"batch={int(batch):2d} repeat={repeat} bw={r['bw']/1024:9.1f} MiB/s")
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1]))); groups={}
for r in rows: groups.setdefault(int(r["batch_size"]),[]).append(float(r["bw_mib_s"]))
with open(sys.argv[2],"w",newline="") as f:
    w=csv.writer(f); w.writerow(["batch_size","n","mean_mib_s","stddev_mib_s","ci95_mib_s"])
    for batch,vals in sorted(groups.items()):
        mean=statistics.mean(vals); std=statistics.stdev(vals) if len(vals)>1 else 0
        ci=1.96*std/math.sqrt(len(vals)) if len(vals)>1 else 0
        w.writerow([batch,len(vals),f"{mean:.3f}",f"{std:.3f}",f"{ci:.3f}"])
        print(f"batch={batch:2d} mean={mean:9.1f} std={std:7.1f} 95%CI=±{ci:6.1f}")
PY
echo "[OK] $RESULT_DIR"
