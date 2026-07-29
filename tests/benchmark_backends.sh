#!/usr/bin/env bash
set -euo pipefail

# Fair sequential comparison of plain, Hook RAW, SGLZ and nvCOMP LZ4.
# All four files are independent copies of one immutable logical input.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/backends_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-backends-XXXXXX)"
RUNTIME="${GPUC_RUNTIME:-2}"
REPEATS="${GPUC_REPEATS:-5}"
BS="${GPUC_BS:-128k}"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"

mkdir -p "$RESULT_DIR/json" "$TEST_DIR/plain" "$TEST_DIR/raw" \
    "$TEST_DIR/sglz" "$TEST_DIR/lz4"
trap 'rm -rf -- "$TEST_DIR"' EXIT

plain="$TEST_DIR/plain/data.bin"
raw="$TEST_DIR/raw/data.bin"
sglz="$TEST_DIR/sglz/data.bin"
lz4="$TEST_DIR/lz4/data.bin"

tar --sort=name --mtime='UTC 2020-01-01' --owner=0 --group=0 --numeric-owner \
    -cf "$plain" -C / usr/include
logical_bytes="$(stat -c %s "$plain")"
sha="$(sha256sum "$plain" | awk '{print $1}')"

for path in "$raw" "$sglz" "$lz4"; do
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$plain" "$path"
done
"$DAEMON" "$TEST_DIR/sglz" >/dev/null
GPUC_ALGO=lz4 "$DAEMON" "$TEST_DIR/lz4" >/dev/null

metadata() {
    python3 - "$1" <<'PY'
import struct,sys
with open(sys.argv[1],"rb") as f: h=f.read(56)
if len(h)<56 or struct.unpack_from("<I",h,0)[0] != 0x47505543:
    print("PLAIN,NONE")
else:
    state={0:"RAW",1:"COMPRESSED",2:"BUSY",3:"INLINE"}.get(h[24],"INVALID")
    algo={0:"NONE",1:"SGLZ",2:"LZ4",3:"SNAPPY"}.get(h[25],"INVALID")
    print(f"{state},{algo}")
PY
}

logical_sha() {
    local scenario="$1" path="$2"
    if [[ "$scenario" == baseline ]]; then
        sha256sum "$path" | awk '{print $1}'
    else
        LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
            dd if="$path" bs=1M status=none | sha256sum | awk '{print $1}'
    fi
}

declare -A paths=( [baseline]="$plain" [hook_raw]="$raw" [sglz]="$sglz" [lz4]="$lz4" )
for scenario in baseline hook_raw sglz lz4; do
    [[ "$(logical_sha "$scenario" "${paths[$scenario]}")" == "$sha" ]]
done
[[ "$(metadata "$plain")" == "PLAIN,NONE" ]]
# RAW headers retain the selected/default future compression algorithm.
[[ "$(metadata "$raw")" == "RAW,SGLZ" ]]
[[ "$(metadata "$sglz")" == "COMPRESSED,SGLZ" ]]
[[ "$(metadata "$lz4")" == "COMPRESSED,LZ4" ]]

# Full logical pre-read defines the warm-cache experiment.
dd if="$plain" of=/dev/null bs=1M status=none
for path in "$raw" "$sglz" "$lz4"; do
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 dd if="$path" of=/dev/null bs=1M status=none
done

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
fio=$(fio --version)
gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)
source=/usr/include deterministic tar (--sort=name, fixed mtime/owner)
logical_bytes=$logical_bytes
logical_sha256=$sha
runtime=$RUNTIME
repeats=$REPEATS
bs=$BS
direct=0
cache_mode=warm (full logical pre-read)
EOF
echo "scenario,repeat,bw_mib_s,iops,mean_lat_us,error,state,algo,logical_sha256,format_bytes,allocated_bytes" \
    > "$RESULT_DIR/runs.csv"

scenarios=(baseline hook_raw sglz lz4)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 4 ))
    for idx in 0 1 2 3; do
        scenario="${scenarios[$(( (idx + shift) % 4 ))]}"
        path="${paths[$scenario]}"
        json="$RESULT_DIR/json/${scenario}_r${repeat}.json"
        if [[ "$scenario" == baseline ]]; then
            fio --name="$scenario" --filename="$path" --size="$logical_bytes" \
                --bs="$BS" --rw=read --runtime="$RUNTIME" --time_based \
                --direct=0 --invalidate=0 --ioengine=sync --numjobs=1 \
                --group_reporting --readonly --output-format=json > "$json"
        else
            LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
                fio --name="$scenario" --filename="$path" --size="$logical_bytes" \
                    --bs="$BS" --rw=read --runtime="$RUNTIME" --time_based \
                    --direct=0 --invalidate=0 --ioengine=sync --numjobs=1 \
                    --group_reporting --readonly --output-format=json > "$json"
        fi
        meta="$(metadata "$path")"
        state="${meta%,*}"; algo="${meta#*,}"
        format_bytes="$(stat -c %s "$path")"
        allocated_bytes="$(du -B1 "$path" | awk '{print $1}')"
        python3 - "$json" "$RESULT_DIR/runs.csv" "$scenario" "$repeat" \
            "$state" "$algo" "$sha" "$format_bytes" "$allocated_bytes" <<'PY'
import csv,json,sys
jpath,out,scenario,repeat,state,algo,sha,fmt,alloc=sys.argv[1:]
d=json.load(open(jpath)); job=d["jobs"][0]; r=job["read"]
lat=r.get("lat_ns",{}).get("mean",0)/1000
row=[scenario,repeat,r["bw"]/1024,r["iops"],lat,job.get("error",0),
     state,algo,sha,fmt,alloc]
with open(out,"a",newline="") as f: csv.writer(f).writerow(row)
print(f"{scenario:10s} repeat={repeat} bw={row[2]:9.1f} MiB/s state={state} algo={algo}")
if int(job.get("error",0)): raise SystemExit(1)
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1]))); groups={}
for r in rows: groups.setdefault(r["scenario"],[]).append(float(r["bw_mib_s"]))
with open(sys.argv[2],"w",newline="") as f:
    w=csv.writer(f); w.writerow(["scenario","n","mean_mib_s","stddev_mib_s","ci95_mib_s"])
    for scenario in ("baseline","hook_raw","sglz","lz4"):
        v=groups[scenario]; mean=statistics.mean(v)
        std=statistics.stdev(v) if len(v)>1 else 0
        ci=1.96*std/math.sqrt(len(v)) if len(v)>1 else 0
        w.writerow([scenario,len(v),f"{mean:.3f}",f"{std:.3f}",f"{ci:.3f}"])
        print(f"{scenario:10s} mean={mean:9.1f} MiB/s 95%CI=±{ci:6.1f}")
PY
echo "[OK] $RESULT_DIR"
